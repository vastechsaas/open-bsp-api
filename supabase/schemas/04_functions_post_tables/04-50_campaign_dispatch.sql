-- Invoker trigger: direct tenant writes cannot choose the execution transport.
create function public.guard_campaign_dispatch_transport() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.status <> 'draft'
    and new.dispatch_transport is distinct from old.dispatch_transport then
    raise exception 'campaign transport is immutable after start' using errcode = '23514';
  end if;
  if current_user in ('anon', 'authenticated') and (
    (tg_op = 'INSERT' and new.dispatch_transport <> 'postgres')
    or (tg_op = 'UPDATE' and new.dispatch_transport is distinct from old.dispatch_transport)
  ) then
    raise exception 'campaign transport is deployment managed' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger guard_campaign_dispatch_transport before insert or update
on public.campaigns for each row execute function public.guard_campaign_dispatch_transport();

-- Called with the parent campaign lock held. Apply deltas, not an O(audience) recount per send.
create function public.set_campaign_dispatch_delivery(p_delivery_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.campaign_deliveries;
begin
  select * into strict d from public.campaign_deliveries where id = p_delivery_id for update;
  if d.status = p_status then return; end if;
  update public.campaign_deliveries set status = p_status where id = d.id;
  update public.campaigns set
    queued_count = queued_count - (d.status = 'queued')::integer + (p_status = 'queued')::integer,
    processing_count = processing_count - (d.status = 'processing')::integer + (p_status = 'processing')::integer,
    accepted_count = accepted_count - (d.status = 'accepted')::integer + (p_status = 'accepted')::integer,
    failed_count = failed_count - (d.status = 'failed')::integer + (p_status = 'failed')::integer,
    needs_review_count = needs_review_count - (d.status = 'needs_review')::integer + (p_status = 'needs_review')::integer
  where id = d.campaign_id;
  update public.campaigns set status = case
    when needs_review_count > 0 then 'needs_review'
    when queued_count + processing_count = 0 then 'completed' else 'running' end
  where id = d.campaign_id;
end;
$$;
revoke all on function public.set_campaign_dispatch_delivery(uuid, text) from public, anon, authenticated;
grant execute on function public.set_campaign_dispatch_delivery(uuid, text) to service_role;

create function public.claim_campaign_dispatch_publications(p_limit integer default 25) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  with candidates as (
    select j.id from public.campaign_dispatch_jobs j
    join public.campaigns c on c.id = j.campaign_id and c.dispatch_transport = 'cloudamqp'
    where j.phase = 'pending' and j.publish_after <= clock_timestamp()
      and (j.publication_expires_at is null or j.publication_expires_at < clock_timestamp())
      and public.is_organization_active(j.organization_id)
    order by j.publish_after, j.id for update of j skip locked
    limit least(greatest(coalesce(p_limit, 25), 1), 100)
  ), claimed as (
    update public.campaign_dispatch_jobs j set publication_token = gen_random_uuid(),
      publication_expires_at = clock_timestamp() + interval '60 seconds', updated_at = clock_timestamp()
    from candidates c where c.id = j.id returning j.*
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'version', 1, 'job_id', id, 'organization_id', organization_id,
      'campaign_id', campaign_id, 'delivery_id', delivery_id,
      'publication_token', publication_token,
      'delay_ms', greatest(0, ceil(extract(epoch from (due_at - clock_timestamp())) * 1000))::integer
    )), '[]'::jsonb) into result from claimed;
  return result;
end;
$$;
revoke all on function public.claim_campaign_dispatch_publications(integer) from public, anon, authenticated;
grant execute on function public.claim_campaign_dispatch_publications(integer) to service_role;

create function public.confirm_campaign_dispatch_publication(p_job_id uuid, p_token uuid) returns boolean
language sql security definer set search_path = '' as $$
  with changed as (
    update public.campaign_dispatch_jobs set
      publish_after = greatest(due_at, clock_timestamp()) + interval '5 minutes',
      publication_token = null, publication_expires_at = null, updated_at = clock_timestamp()
    where id = p_job_id and publication_token = p_token and phase = 'pending'
    returning id
  ) select exists (select 1 from changed);
$$;
revoke all on function public.confirm_campaign_dispatch_publication(uuid, uuid) from public, anon, authenticated;
grant execute on function public.confirm_campaign_dispatch_publication(uuid, uuid) to service_role;

create function public.claim_campaign_dispatch_job(p_job_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare j public.campaign_dispatch_jobs; c public.campaigns;
begin
  select campaign_id into j.campaign_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then return null; end if;
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if c.dispatch_transport <> 'cloudamqp' then raise exception 'wrong campaign transport'; end if;
  if j.phase <> 'pending' then return jsonb_build_object('phase', j.phase); end if;
  if j.due_at > clock_timestamp() then
    update public.campaign_dispatch_jobs set publish_after = due_at where id = j.id;
    return jsonb_build_object('phase', 'deferred');
  end if;
  if not public.is_organization_active(j.organization_id) or not exists (
    select 1 from public.organizations_addresses a where a.organization_id = j.organization_id
      and a.address = c.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then
    update public.campaign_dispatch_jobs set phase = 'failed', error_code = 'account_unavailable', updated_at = clock_timestamp() where id = j.id;
    update public.campaign_deliveries set error = jsonb_build_object('code', 'account_unavailable', 'job_id', j.id) where id = j.delivery_id;
    perform public.set_campaign_dispatch_delivery(j.delivery_id, 'failed');
    return jsonb_build_object('phase', 'failed');
  end if;
  update public.campaign_dispatch_jobs set phase = 'preparing', lease_token = gen_random_uuid(),
    lease_expires_at = clock_timestamp() + interval '3 minutes', updated_at = clock_timestamp()
  where id = j.id returning * into j;
  perform public.set_campaign_dispatch_delivery(j.delivery_id, 'processing');
  return jsonb_build_object('phase', 'claimed', 'lease_token', j.lease_token);
end;
$$;
revoke all on function public.claim_campaign_dispatch_job(uuid) from public, anon, authenticated;
grant execute on function public.claim_campaign_dispatch_job(uuid) to service_role;

-- Commit the uncertainty boundary before performing the external side effect.
create function public.begin_campaign_dispatch_send(p_job_id uuid, p_token uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare j public.campaign_dispatch_jobs; c public.campaigns;
begin
  select campaign_id into j.campaign_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then return false; end if;
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if j.phase <> 'preparing' or j.lease_token is distinct from p_token
    or j.lease_expires_at <= clock_timestamp() then return false; end if;
  if not public.is_organization_active(j.organization_id) or not exists (
    select 1 from public.organizations_addresses a where a.organization_id = j.organization_id
      and a.address = c.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then return false; end if;
  update public.campaign_dispatch_jobs set phase = 'submitting', send_started_at = clock_timestamp(),
    lease_expires_at = clock_timestamp() + interval '2 minutes', updated_at = clock_timestamp() where id = j.id;
  update public.campaign_deliveries set attempts = attempts + 1 where id = j.delivery_id;
  return true;
end;
$$;
revoke all on function public.begin_campaign_dispatch_send(uuid, uuid) from public, anon, authenticated;
grant execute on function public.begin_campaign_dispatch_send(uuid, uuid) to service_role;

create function public.finish_campaign_dispatch_job(
  p_job_id uuid, p_token uuid, p_outcome text, p_external_id text default null, p_error_code text default null
) returns text language plpgsql security definer set search_path = '' as $$
declare j public.campaign_dispatch_jobs; c public.campaigns; next_due timestamptz; result text;
begin
  if p_outcome not in ('accepted', 'failed', 'retry', 'needs_review')
    or (p_error_code is not null and p_error_code !~ '^[a-zA-Z0-9_.:-]{1,100}$') then
    raise exception 'invalid dispatch result';
  end if;
  select campaign_id into j.campaign_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then raise exception 'job not found'; end if;
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if j.lease_token is distinct from p_token or p_token is null then raise exception 'stale dispatch lease'; end if;
  if j.phase in ('accepted', 'failed', 'retry_scheduled') then return j.phase; end if;
  -- A late known WAMID may resolve this exact attempt's uncertainty, never a new attempt.
  if j.phase = 'needs_review' and p_outcome <> 'accepted' then return j.phase; end if;
  if j.phase not in ('preparing', 'submitting', 'needs_review') then raise exception 'job not processing'; end if;
  if p_outcome = 'accepted' and (j.send_started_at is null or coalesce(p_external_id, '') = '') then
    raise exception 'accepted send requires message ID and submission';
  end if;
  result := p_outcome;
  if p_outcome = 'retry' then
    if j.attempt_no < 3 then
      next_due := clock_timestamp() + make_interval(secs => (30 * power(2, j.attempt_no - 1) * (1 + random() * 0.2)));
      insert into public.campaign_dispatch_jobs (organization_id, campaign_id, delivery_id, attempt_no, due_at)
      values (j.organization_id, j.campaign_id, j.delivery_id, j.attempt_no + 1, next_due)
      on conflict (delivery_id, attempt_no) do nothing;
      result := 'retry_scheduled';
    else result := 'failed'; end if;
  end if;
  update public.campaign_dispatch_jobs set phase = result, external_id = p_external_id,
    error_code = p_error_code, lease_expires_at = null, updated_at = clock_timestamp() where id = j.id;
  update public.campaign_deliveries set external_id = coalesce(p_external_id, external_id),
    error = case when result = 'accepted' then null else jsonb_build_object('code', coalesce(p_error_code, result), 'job_id', j.id) end
  where id = j.delivery_id;
  perform public.set_campaign_dispatch_delivery(j.delivery_id, case when result = 'retry_scheduled' then 'queued' else result end);
  return result;
end;
$$;
revoke all on function public.finish_campaign_dispatch_job(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.finish_campaign_dispatch_job(uuid, uuid, text, text, text) to service_role;

create function public.recover_campaign_dispatch_jobs() returns integer
language plpgsql security definer set search_path = '' as $$
declare candidate record; j public.campaign_dispatch_jobs; recovered integer := 0;
begin
  for candidate in select id, campaign_id from public.campaign_dispatch_jobs
    where phase in ('preparing', 'submitting') and lease_expires_at < clock_timestamp()
    order by lease_expires_at, id limit 100
  loop
    -- Same parent -> job lock order as dispatch, including recheck after waiting.
    perform 1 from public.campaigns where id = candidate.campaign_id for update;
    select * into j from public.campaign_dispatch_jobs where id = candidate.id for update;
    if j.phase not in ('preparing', 'submitting') or j.lease_expires_at >= clock_timestamp() then continue; end if;
    if j.phase = 'submitting' then
      perform public.finish_campaign_dispatch_job(j.id, j.lease_token, 'needs_review', null, 'submission_outcome_unknown');
    else
      update public.campaign_dispatch_jobs set phase = 'pending', lease_token = null, lease_expires_at = null,
        publication_token = null, publication_expires_at = null, publish_after = clock_timestamp(), updated_at = clock_timestamp()
      where id = j.id;
      perform public.set_campaign_dispatch_delivery(j.delivery_id, 'queued');
    end if;
    recovered := recovered + 1;
  end loop;
  return recovered;
end;
$$;
revoke all on function public.recover_campaign_dispatch_jobs() from public, anon, authenticated;
grant execute on function public.recover_campaign_dispatch_jobs() to service_role;
