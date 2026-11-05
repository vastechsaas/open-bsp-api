create function public.reserve_media_preprocessing(p_message_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare m public.messages; j public.media_preprocessing_jobs; token uuid;
begin
  select * into m from public.messages where id=p_message_id for update;
  if not found or m.content->>'type' is distinct from 'file'
    or m.direction not in ('incoming','outgoing') or not (m.status ? 'pending')
    or m.status ? 'preprocessed' or not public.is_organization_active(m.organization_id)
    or not exists(select 1 from public.organizations o where o.id=m.organization_id
      and o.extra->'media_preprocessing'->>'mode'='active') then return null; end if;
  insert into public.media_preprocessing_jobs(message_id,organization_id,state)
    values(m.id,m.organization_id,'retry_wait') on conflict do nothing;
  select * into strict j from public.media_preprocessing_jobs where message_id=m.id for update;
  if j.state in ('succeeded','skipped','failed') or j.next_attempt_at>clock_timestamp() then return null; end if;
  if j.attempts>=3 or m.timestamp<clock_timestamp()-interval '12 hours' then
    update public.media_preprocessing_jobs set state='failed',lease_token=null,
      last_error_code='retry_exhausted',updated_at=clock_timestamp() where message_id=m.id;
    update public.messages set status=jsonb_build_object('preprocessed',clock_timestamp()) where id=m.id;
    return null;
  end if;
  token:=gen_random_uuid();
  update public.media_preprocessing_jobs set state='queued',attempts=attempts+1,
    lease_token=token,next_attempt_at=clock_timestamp()+interval '2 minutes',
    updated_at=clock_timestamp() where message_id=m.id;
  return token;
end;
$$;

create function public.start_media_preprocessing(p_message_id uuid,p_token uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare m public.messages;
begin
  select * into m from public.messages where id=p_message_id for update;
  if not found or m.content->>'type' is distinct from 'file' or m.status ? 'preprocessed'
    or not public.is_organization_active(m.organization_id)
    or not exists(select 1 from public.organizations o where o.id=m.organization_id
      and o.extra->'media_preprocessing'->>'mode'='active') then return false; end if;
  update public.media_preprocessing_jobs set state='processing',
    next_attempt_at=clock_timestamp()+interval '10 minutes',updated_at=clock_timestamp()
    where message_id=m.id and state='queued' and lease_token=p_token
      and next_attempt_at>clock_timestamp();
  if not found then return false; end if;
  update public.messages set status=jsonb_build_object('preprocessing',clock_timestamp()) where id=m.id;
  return true;
end;
$$;

create function public.finish_media_preprocessing(
  p_message_id uuid,p_token uuid,p_outcome text,p_artifacts jsonb default null
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare j public.media_preprocessing_jobs; terminal boolean; result text;
begin
  if p_outcome not in ('succeeded','skipped','retry') or
    (p_artifacts is not null and (p_outcome<>'succeeded' or jsonb_typeof(p_artifacts)<>'array')) then
    raise exception 'Invalid preprocessing result' using errcode='22023'; end if;
  -- Same lock order as reserve/start. A stale worker cannot overwrite new evidence.
  perform 1 from public.messages where id=p_message_id for update;
  select * into j from public.media_preprocessing_jobs where message_id=p_message_id for update;
  if not found or j.state<>'processing' or j.lease_token is distinct from p_token
    or p_token is null or j.next_attempt_at<=clock_timestamp() then return false; end if;
  result:=case when p_outcome='retry' then
    case when j.attempts>=3 then 'failed' else 'retry_wait' end else p_outcome end;
  terminal:=result in ('succeeded','skipped','failed');
  update public.media_preprocessing_jobs set state=result,lease_token=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>60*power(2,j.attempts-1)::integer),
    last_error_code=case when result='failed' then 'retry_exhausted'
      when result='retry_wait' then 'processing_unavailable' else null end,
    updated_at=clock_timestamp() where message_id=p_message_id;
  if terminal then
    update public.messages set
      content=case when p_artifacts is not null then jsonb_set(content,'{artifacts}',p_artifacts) else content end,
      status=jsonb_build_object('preprocessed',clock_timestamp())
      where id=p_message_id;
  end if;
  return true;
end;
$$;

create function public.enqueue_media_preprocessing(p_message_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare token uuid; base_url text; credential text;
begin
  token:=public.reserve_media_preprocessing(p_message_id);
  if token is null then return false; end if;
  select decrypted_secret into base_url from vault.decrypted_secrets where name='edge_functions_url';
  select decrypted_secret into credential from vault.decrypted_secrets where name='edge_functions_token';
  if coalesce(base_url,'')='' or coalesce(credential,'')='' then
    update public.media_preprocessing_jobs set last_error_code='configuration_unavailable'
      where message_id=p_message_id and lease_token=token;
    return false;
  end if;
  perform net.http_post(
    url:=rtrim(base_url,'/')||'/media-preprocessor',
    headers:=jsonb_build_object('content-type','application/json','authorization','Bearer '||credential),
    body:=jsonb_build_object('message_id',p_message_id,'lease_token',token),
    timeout_milliseconds:=10000
  );
  return true;
end;
$$;

create function public.enqueue_pending_media_preprocessing(p_limit integer default 25) returns integer
language plpgsql security definer set search_path = '' as $$
declare candidate record; queued integer:=0;
begin
  for candidate in
    select m.id from public.messages m
    join public.organizations o on o.id=m.organization_id
    left join public.media_preprocessing_jobs j on j.message_id=m.id
    where m.direction in ('incoming','outgoing') and m.content->>'type'='file'
      and m.status ? 'pending' and not (m.status ? 'preprocessed')
      and o.extra->'media_preprocessing'->>'mode'='active'
      and public.is_organization_active(o.id)
      and m.timestamp<=clock_timestamp()-interval '1 minute'
      and (m.timestamp>=clock_timestamp()-interval '12 hours' or j.message_id is not null)
      and (j.message_id is null or (j.state in ('queued','processing','retry_wait') and j.next_attempt_at<=clock_timestamp()))
    order by coalesce(j.next_attempt_at,m.timestamp),m.id
    limit least(greatest(coalesce(p_limit,25),1),50)
    for update of m skip locked
  loop
    if public.enqueue_media_preprocessing(candidate.id) then queued:=queued+1; end if;
  end loop;
  return queued;
end;
$$;

revoke all on function public.reserve_media_preprocessing(uuid),
  public.start_media_preprocessing(uuid,uuid),
  public.finish_media_preprocessing(uuid,uuid,text,jsonb),
  public.enqueue_media_preprocessing(uuid),
  public.enqueue_pending_media_preprocessing(integer)
  from public,anon,authenticated;
grant execute on function public.reserve_media_preprocessing(uuid),
  public.start_media_preprocessing(uuid,uuid),
  public.finish_media_preprocessing(uuid,uuid,text,jsonb),
  public.enqueue_media_preprocessing(uuid),
  public.enqueue_pending_media_preprocessing(integer)
  to service_role;
