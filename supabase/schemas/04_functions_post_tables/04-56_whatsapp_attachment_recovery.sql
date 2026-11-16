create function public.persist_whatsapp_attachment_messages(p_messages jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare inserted integer;
begin
  if jsonb_typeof(p_messages) is distinct from 'array' then
    raise exception 'Invalid attachment message batch';
  end if;
  with new_messages as (
    insert into public.messages (
      organization_id, conversation_id, external_id, direction, service,
      organization_address, contact_address, group_address, content, timestamp
    )
    select v.organization_id, v.conversation_id, v.external_id, 'incoming', 'whatsapp',
      v.organization_address, v.contact_address, v.group_address,
      jsonb_set(v.content, '{attachment_recovery}', '"pending"'), v.timestamp
    from jsonb_populate_recordset(null::public.messages, p_messages) v
    where v.direction = 'incoming' and v.service = 'whatsapp'
      and v.external_id is not null and v.content->>'type' = 'file'
      and v.content#>>'{file,uri}' ~ '^[0-9]{1,40}$'
    on conflict (external_id) do nothing
    returning id, content
  )
  insert into public.whatsapp_attachment_recovery_jobs (message_id, media_id)
  select id, content#>>'{file,uri}' from new_messages;
  get diagnostics inserted = row_count;
  return inserted;
end;
$$;

-- A late duplicate/history upsert must not revert a completed attachment or
-- put an inline download error back on a message that has a durable job.
create function public.preserve_whatsapp_attachment_recovery()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.service = 'whatsapp' and old.direction = 'incoming'
    and (old.content ? 'attachment_recovery' or old.content#>>'{file,uri}' like 'internal://media/%')
    and new.content#>>'{file,uri}' ~ '^[0-9]{1,40}$'
    and new.content ? 'file'
    and not (new.content ? 'attachment_recovery')
  then
    new.content := jsonb_set(new.content, '{file}', old.content->'file');
    if old.content ? 'attachment_recovery' then
      new.content := jsonb_set(new.content, '{attachment_recovery}', old.content->'attachment_recovery');
    end if;
    if new.status ? 'error' then
      new.status := (new.status - 'error') ||
        case when old.status ? 'error' then jsonb_build_object('error', old.status->'error') else '{}'::jsonb end;
    end if;
  end if;
  return new;
end;
$$;
create trigger preserve_whatsapp_attachment_recovery before update on public.messages
for each row execute function public.preserve_whatsapp_attachment_recovery();

create function public.finish_whatsapp_attachment_recovery(
  p_message_id uuid, p_lease_token uuid, p_outcome text,
  p_path text default null, p_size integer default null, p_retry_after integer default 0
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  job public.whatsapp_attachment_recovery_jobs;
  message public.messages;
  outcome text := p_outcome;
  delay_seconds integer := least(86400, greatest(0, coalesce(p_retry_after,0)));
begin
  select * into job from public.whatsapp_attachment_recovery_jobs
  where message_id = p_message_id and state = 'pending' and lease_token = p_lease_token for update;
  if not found then return false; end if;
  if outcome = 'ready' and job.lease_until <= now() then return false; end if;

  if outcome is null or outcome not in ('ready','temporary','unavailable','credentials','storage','too_large','cancelled') then
    raise exception 'Invalid attachment recovery outcome';
  end if;
  select * into message from public.messages where id = p_message_id for update;
  if not found or message.status ? 'deleted' or message.content#>>'{file,uri}' is distinct from job.media_id then
    outcome := 'cancelled';
  elsif not public.is_organization_active(message.organization_id) then
    outcome := 'cancelled';
  elsif outcome <> 'cancelled' and not exists (
    select 1 from public.organizations_addresses a where a.organization_id = message.organization_id
    and a.address = message.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then
    outcome := 'credentials';
  end if;

  if outcome = 'ready' then
    if p_path is null or p_path !~ ('^organizations/' || message.organization_id || '/attachments/[a-zA-Z0-9_-]{43}$')
      or p_size is null or p_size < 1
      or not exists (select 1 from storage.objects where bucket_id = 'media' and name = p_path
        and metadata->>'size' = p_size::text)
    then raise exception 'Attachment storage object not verified'; end if;
    update public.messages set content = jsonb_build_object('attachment_recovery','ready',
      'file',jsonb_build_object('uri','internal://media/' || p_path, 'size',p_size)) where id = p_message_id;
  elsif outcome = 'temporary' and not job.manual and job.automatic_attempts < 4 then
    delay_seconds := greatest(case job.automatic_attempts when 1 then 30 when 2 then 120 else 600 end,
      delay_seconds);
    outcome := 'pending';
  else
    if outcome = 'temporary' then outcome := 'failed'; end if;
    if message.id is not null and not (message.status ? 'deleted')
      and message.content#>>'{file,uri}' = job.media_id then
      update public.messages set content = jsonb_build_object('attachment_recovery',outcome)
      where id = p_message_id;
    end if;
  end if;
  update public.whatsapp_attachment_recovery_jobs set state = outcome,
    next_attempt_at = now() + make_interval(secs => delay_seconds), lease_token = null, lease_until = null
    where message_id = p_message_id;
  return true;
end;
$$;

create function public.claim_whatsapp_attachment_recovery()
returns table (message_id uuid, lease_token uuid)
language plpgsql security definer set search_path = '' as $$
declare stale record;
begin
  if not pg_try_advisory_xact_lock(824038171) then return; end if;
  for stale in
    select j.message_id, j.lease_token from public.whatsapp_attachment_recovery_jobs j
    where j.state = 'pending' and j.lease_until <= now() order by j.lease_until limit 5
    for update skip locked
  loop
    perform public.finish_whatsapp_attachment_recovery(stale.message_id,stale.lease_token,'temporary');
  end loop;
  -- Cap total parallel transfers across overlapping Edge invocations.
  if (select count(*) from public.whatsapp_attachment_recovery_jobs j where j.lease_until > now()) >= 2
  then return; end if;
  return query
    with due as (
      select j.message_id from public.whatsapp_attachment_recovery_jobs j
      where j.state = 'pending' and j.next_attempt_at <= now() and j.lease_token is null
      order by j.next_attempt_at, j.message_id limit 1 for update skip locked
    )
    update public.whatsapp_attachment_recovery_jobs j set lease_token = gen_random_uuid(),
      lease_until = now() + interval '120 seconds',
      automatic_attempts = j.automatic_attempts + case when j.manual then 0 else 1 end
    from due where j.message_id = due.message_id returning j.message_id, j.lease_token;
end;
$$;

create function public.whatsapp_attachment_recovery_context(p_message_id uuid, p_lease_token uuid)
returns table (media_id text, organization_id uuid, organization_address text, account_status text, access_token text, filename text)
language sql stable security definer set search_path = '' as $$
  select j.media_id, m.organization_id, m.organization_address, a.status, a.extra->>'access_token', m.content#>>'{file,name}'
  from public.whatsapp_attachment_recovery_jobs j
  join public.messages m on m.id = j.message_id
  left join public.organizations_addresses a on a.organization_id = m.organization_id
    and a.address = m.organization_address and a.service = 'whatsapp'
  where j.message_id = p_message_id and j.lease_token = p_lease_token and j.lease_until > now()
    and m.service = 'whatsapp' and m.direction = 'incoming' and not (m.status ? 'deleted')
    and m.content#>>'{file,uri}' = j.media_id and public.is_organization_active(m.organization_id);
$$;

create function public.retry_whatsapp_attachment_recovery(p_message_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare message public.messages; job public.whatsapp_attachment_recovery_jobs;
begin
  select * into message from public.messages where id = p_message_id;
  if not found or auth.uid() is null or not public.is_organization_active(message.organization_id)
    or not (message.organization_id in (select public.get_authorized_orgs('member'))
      or coalesce(public.agent_can_read_conversation(message.organization_id, message.conversation_id), false))
  then return 'not_found'; end if;
  select * into job from public.whatsapp_attachment_recovery_jobs where message_id = p_message_id for update;
  if not found then return 'not_found'; end if;
  -- Recheck current record after waiting for any running completion.
  select * into message from public.messages where id = p_message_id;
  if not found or message.status ? 'deleted' or (job.state <> 'ready' and
    message.content#>>'{file,uri}' is distinct from job.media_id)
  then return 'not_found'; end if;
  if job.state in ('pending','ready') then return job.state; end if;
  if job.state not in ('failed','credentials','storage') then return job.state; end if;
  if job.manual_attempts >= 2 then return 'limit'; end if;
  if job.next_attempt_at > now() then return 'rate_limited'; end if;
  if job.manual_requested_at > now() - interval '5 minutes' then return 'cooldown'; end if;
  update public.whatsapp_attachment_recovery_jobs set state='pending', manual=true,
    manual_attempts=manual_attempts+1, manual_requested_at=now(), next_attempt_at=now()
    where message_id = p_message_id;
  update public.messages set content=jsonb_build_object('attachment_recovery','pending') where id=p_message_id;
  return 'pending';
end;
$$;

create function public.wake_whatsapp_attachment_recovery()
returns void language plpgsql security definer set search_path = '' as $$
declare base text; token text;
begin
  if not exists (select 1 from public.whatsapp_attachment_recovery_jobs j
    where j.state='pending' and j.next_attempt_at <= now() and (j.lease_until is null or j.lease_until <= now()))
  then return; end if;
  select decrypted_secret into base from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into token from vault.decrypted_secrets where name = 'edge_functions_token';
  if coalesce(base,'') = '' or coalesce(token,'') = '' then return; end if;
  perform net.http_post(url := rtrim(base,'/') || '/whatsapp-attachment-recovery',
    headers := jsonb_build_object('authorization','Bearer ' || token, 'content-type','application/json'),
    timeout_milliseconds := 110000);
end;
$$;

create trigger handle_recovered_attachment_media_preprocessing after update on public.messages
for each row when (
  new.content->>'attachment_recovery' = 'ready'
  and old.content->>'attachment_recovery' is distinct from 'ready'
  and new.status ? 'pending' and not (new.status ? 'preprocessed')
) execute function public.edge_function('/media-preprocessor', 'post');

revoke all on function public.persist_whatsapp_attachment_messages(jsonb),
  public.preserve_whatsapp_attachment_recovery(),
  public.finish_whatsapp_attachment_recovery(uuid,uuid,text,text,integer,integer),
  public.claim_whatsapp_attachment_recovery(),
  public.whatsapp_attachment_recovery_context(uuid,uuid),
  public.retry_whatsapp_attachment_recovery(uuid),
  public.wake_whatsapp_attachment_recovery()
from public, anon, authenticated;
grant execute on function public.persist_whatsapp_attachment_messages(jsonb),
  public.finish_whatsapp_attachment_recovery(uuid,uuid,text,text,integer,integer),
  public.claim_whatsapp_attachment_recovery(),
  public.whatsapp_attachment_recovery_context(uuid,uuid)
to service_role;
grant execute on function public.retry_whatsapp_attachment_recovery(uuid) to authenticated;
