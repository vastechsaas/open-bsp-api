-- All send/policy operations take this lock BEFORE campaign -> job row locks.
create function public.lock_campaign_sending_policy(p_organization_id uuid) returns void
language sql volatile set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('campaign-policy:' || p_organization_id::text, 0));
$$;
revoke all on function public.lock_campaign_sending_policy(uuid) from public, anon, authenticated;
grant execute on function public.lock_campaign_sending_policy(uuid) to service_role;

create function public.campaign_recipient_key(p_address text) returns text
language sql immutable set search_path = '' as $$
  select case when btrim(p_address) ~ '^\+?[0-9 ()-]+$'
    then regexp_replace(p_address, '[^0-9]', '', 'g') else lower(btrim(p_address)) end;
$$;
revoke all on function public.campaign_recipient_key(text) from public;
grant execute on function public.campaign_recipient_key(text) to service_role;

create function public.campaign_window_next_at(p_at timestamptz, p_timezone text, p_start time, p_end time)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare local_at timestamp; candidate timestamptz;
begin
  if p_start is null then return p_at; end if;
  local_at := p_at at time zone p_timezone;
  if p_start < p_end then
    if local_at::time >= p_start and local_at::time < p_end then return p_at; end if;
    candidate := ((local_at::date + case when local_at::time >= p_end then 1 else 0 end) + p_start) at time zone p_timezone;
  else
    if local_at::time >= p_start or local_at::time < p_end then return p_at; end if;
    candidate := (local_at::date + p_start) at time zone p_timezone;
  end if;
  -- A skipped local time is resolved forward by PostgreSQL, never before p_at.
  return greatest(p_at, candidate);
end;
$$;
revoke all on function public.campaign_window_next_at(timestamptz,text,time,time) from public;
grant execute on function public.campaign_window_next_at(timestamptz,text,time,time) to service_role;

create function public.get_platform_campaign_policy(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  perform public.require_platform_admin();
  if not exists (select 1 from public.organizations where id=p_organization_id) then
    raise exception 'Organization not found' using errcode='P0002'; end if;
  select to_jsonb(p) into result from public.campaign_sending_policies p where organization_id=p_organization_id;
  return coalesce(result, jsonb_build_object('organization_id',p_organization_id,'enabled',false,'revision',0,
    'daily_limit',null,'max_sends_per_minute',null,'recipient_cap',null,'budget_timezone','UTC')) ||
    jsonb_build_object('cloudamqp_enabled',exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled));
end;
$$;

create function public.update_platform_campaign_policy(p_organization_id uuid, p_policy jsonb, p_expected_revision bigint, p_request_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare actor uuid; previous jsonb; result jsonb; event public.platform_admin_action_events;
  current_revision bigint; enabled_value boolean; zone text;
begin
  actor := public.require_platform_admin();
  if p_request_id is null or p_expected_revision is null or jsonb_typeof(p_policy) is distinct from 'object'
    or jsonb_typeof(p_policy->'enabled') is distinct from 'boolean'
    or exists (select 1 from jsonb_object_keys(p_policy) k where k not in ('enabled','daily_limit','max_sends_per_minute','recipient_cap','budget_timezone')) then
    raise exception 'Complete valid policy, revision and request ID required' using errcode='22023'; end if;
  enabled_value := (p_policy->>'enabled')::boolean;
  if exists(select 1 from jsonb_each(p_policy) v where v.key in ('daily_limit','max_sends_per_minute','recipient_cap')
    and jsonb_typeof(v.value) not in ('number','null')) then
    raise exception 'Campaign limits must be numeric' using errcode='22023'; end if;
  zone := p_policy->>'budget_timezone';
  if zone is null or not exists (select 1 from pg_timezone_names where name=zone) then
    raise exception 'Valid budget time zone required' using errcode='22023'; end if;
  if enabled_value and (coalesce(p_policy->>'daily_limit','') !~ '^[1-9][0-9]{0,8}$'
    or coalesce(p_policy->>'max_sends_per_minute','') !~ '^[1-9][0-9]{0,4}$'
    or coalesce(p_policy->>'recipient_cap','') !~ '^[1-9][0-9]{0,5}$') then
    raise exception 'Positive finite campaign limits required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,0));
  select * into event from public.platform_admin_action_events where platform_admin_user_id=actor and request_id=p_request_id;
  if found then
    if event.action_type <> 'organization_campaign_policy.update' or event.organization_id is distinct from p_organization_id
      or event.after_state->'request_policy' is distinct from p_policy
      or (event.after_state->>'expected_revision')::bigint is distinct from p_expected_revision then
      raise exception 'Request ID already used for a different action' using errcode='22023'; end if;
    return event.after_state->'result';
  end if;
  perform public.lock_campaign_sending_policy(p_organization_id);
  previous := public.get_platform_campaign_policy(p_organization_id);
  current_revision := (previous->>'revision')::bigint;
  if current_revision <> p_expected_revision then raise exception 'Campaign policy changed. Reload before saving.' using errcode='40001'; end if;
  if enabled_value is distinct from (previous->>'enabled')::boolean and exists (
    select 1 from public.campaigns c where c.organization_id=p_organization_id
      and (c.queued_count+c.processing_count+c.needs_review_count > 0)
  ) then raise exception 'Drain or reconcile active campaigns before changing policy enforcement' using errcode='23514'; end if;
  if enabled_value and not exists (select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled) then
    raise exception 'CloudAMQP campaign processing must be enabled first' using errcode='23514'; end if;
  if zone is distinct from previous->>'budget_timezone' and exists (
    select 1 from public.campaign_send_ledger where organization_id=p_organization_id and submitted_at>clock_timestamp()-interval '48 hours'
  ) then raise exception 'Budget time zone cannot change within 48 hours of campaign submissions' using errcode='23514'; end if;
  -- Seed trustworthy historical acceptance before enforcement, never reset usage.
  insert into public.campaign_send_ledger(organization_id,delivery_id,legacy_delivery_id,organization_address,recipient_key,submitted_at,accepted_at,state)
  select d.organization_id,d.id,d.id,c.organization_address,public.campaign_recipient_key(d.contact_address),d.updated_at,d.updated_at,'accepted'
  from public.campaign_deliveries d join public.campaigns c on c.id=d.campaign_id
  where d.organization_id=p_organization_id and d.status='accepted' and d.updated_at>clock_timestamp()-interval '48 hours'
    and not exists (select 1 from public.campaign_send_ledger l where l.delivery_id=d.id and l.state <> 'released')
  on conflict (legacy_delivery_id) do nothing;
  insert into public.campaign_sending_policies(organization_id,enabled,daily_limit,max_sends_per_minute,recipient_cap,budget_timezone,revision)
  values (p_organization_id,enabled_value,(p_policy->>'daily_limit')::integer,(p_policy->>'max_sends_per_minute')::integer,
    (p_policy->>'recipient_cap')::integer,zone,current_revision+1)
  on conflict (organization_id) do update set enabled=excluded.enabled,daily_limit=excluded.daily_limit,
    max_sends_per_minute=excluded.max_sends_per_minute,recipient_cap=excluded.recipient_cap,
    budget_timezone=excluded.budget_timezone,revision=excluded.revision,updated_at=clock_timestamp();
  -- Wake deferred work on policy edits, but never release its existing reservations.
  update public.campaign_dispatch_jobs set due_at=least(due_at,clock_timestamp()),publish_after=clock_timestamp(),
    publication_token=null,publication_expires_at=null
  where organization_id=p_organization_id and phase='pending' and waiting_reason is not null;
  result := public.get_platform_campaign_policy(p_organization_id);
  insert into public.platform_admin_action_events(platform_admin_user_id,organization_id,action_type,target_type,target_id,request_id,before_state,after_state)
  values(actor,p_organization_id,'organization_campaign_policy.update','organization_campaign_policy',p_organization_id::text,p_request_id,previous,
    jsonb_build_object('result',result,'request_policy',p_policy,'expected_revision',p_expected_revision));
  perform realtime.send('{}'::jsonb,'module-permissions','module-permissions:'||p_organization_id::text,true);
  return result;
end;
$$;

create function public.get_campaign_sending_policy(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.campaign_sending_policies; used bigint; resets timestamptz;
begin
  if public.get_request_organization_role(p_organization_id) not in ('owner','admin','member')
    or public.get_request_organization_role(p_organization_id) is null then
    raise exception 'Campaign access required' using errcode='42501'; end if;
  select * into p from public.campaign_sending_policies where organization_id=p_organization_id;
  if not found then return jsonb_build_object('enabled',false,'revision',0,'budget_timezone','UTC',
    'cloudamqp_enabled',exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled)); end if;
  resets := (((clock_timestamp() at time zone p.budget_timezone)::date+1)::timestamp) at time zone p.budget_timezone;
  select count(*) into used from public.campaign_send_ledger where organization_id=p_organization_id and state <> 'released'
    and submitted_at >= (((clock_timestamp() at time zone p.budget_timezone)::date)::timestamp at time zone p.budget_timezone);
  return to_jsonb(p) || jsonb_build_object('used',used,'remaining',greatest(0,p.daily_limit-used),'resets_at',resets,
    'cloudamqp_enabled',exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled));
end;
$$;

-- Invoked under the organization lock, both before preparation and at submission.
create function public.campaign_dispatch_eligibility(p_job_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare j public.campaign_dispatch_jobs; c public.campaigns; p public.campaign_sending_policies;
  current_at timestamptz := clock_timestamp(); candidate timestamptz; boundary timestamptz;
  earliest timestamptz; latest timestamptz; used bigint; effective_rate integer;
  reason text; recipient text;
begin
  select * into strict j from public.campaign_dispatch_jobs where id=p_job_id;
  select * into strict c from public.campaigns where id=j.campaign_id;
  if c.cancelled_at is not null then return jsonb_build_object('terminal','cancelled'); end if;
  if c.expires_at <= current_at then return jsonb_build_object('terminal','expired'); end if;
  candidate := greatest(current_at,coalesce(c.scheduled_start_at,current_at));
  if candidate > current_at then reason := 'scheduled'; end if;
  select * into p from public.campaign_sending_policies where organization_id=j.organization_id;
  if c.policy_required and (not found or not p.enabled) then
    return jsonb_build_object('reason','policy_unavailable','next_at',current_at+interval '1 minute'); end if;
  if p.enabled then
    boundary := (((current_at at time zone p.budget_timezone)::date)::timestamp) at time zone p.budget_timezone;
    select count(*) into used from public.campaign_send_ledger
      where organization_id=j.organization_id and state <> 'released' and submitted_at >= boundary;
    if used >= p.daily_limit then
      candidate := greatest(candidate,(((current_at at time zone p.budget_timezone)::date+1)::timestamp) at time zone p.budget_timezone);
      reason := 'daily_allowance';
    end if;
    select public.campaign_recipient_key(contact_address) into recipient from public.campaign_deliveries where id=j.delivery_id;
    select count(*),min(greatest(submitted_at,coalesce(accepted_at,submitted_at))) into used,earliest
    from public.campaign_send_ledger where organization_id=j.organization_id and recipient_key=recipient and state <> 'released'
      and greatest(submitted_at,coalesce(accepted_at,submitted_at)) > current_at-interval '24 hours';
    if used >= p.recipient_cap then
      -- If the cap was lowered, enough oldest reservations must age out.
      select greatest(submitted_at,coalesce(accepted_at,submitted_at))+interval '24 hours' into earliest
      from public.campaign_send_ledger where organization_id=j.organization_id and recipient_key=recipient and state <> 'released'
        and greatest(submitted_at,coalesce(accepted_at,submitted_at)) > current_at-interval '24 hours'
      order by greatest(submitted_at,coalesce(accepted_at,submitted_at)),id offset (used-p.recipient_cap) limit 1;
      if earliest > candidate then candidate:=earliest; reason:='recipient_frequency'; end if;
    end if;
  end if;
  effective_rate := least(case when p.enabled then p.max_sends_per_minute else null end,c.max_sends_per_minute);
  if effective_rate is not null then
    select max(submitted_at),count(*) into latest,used from public.campaign_send_ledger
      where organization_id=j.organization_id and organization_address=c.organization_address and submitted_at>current_at-interval '60 seconds';
    earliest := latest + interval '1 second' * (60.0/effective_rate);
    if used >= effective_rate then
      select submitted_at+interval '60 seconds' into boundary from public.campaign_send_ledger
      where organization_id=j.organization_id and organization_address=c.organization_address and submitted_at>current_at-interval '60 seconds'
      order by submitted_at,id offset (used-effective_rate) limit 1;
      earliest := greatest(earliest,boundary);
    end if;
    if earliest > candidate then candidate:=earliest; reason:='number_rate'; end if;
  end if;
  boundary := public.campaign_window_next_at(candidate,c.schedule_timezone,c.send_window_start,c.send_window_end);
  if boundary > candidate then candidate:=boundary; if reason is null then reason:='sending_window'; end if; end if;
  if c.expires_at is not null and candidate >= c.expires_at then
    -- Keep waiting visible until expiry; do not report expiration before its time.
    candidate:=c.expires_at;
  end if;
  if candidate > current_at then return jsonb_build_object('reason',coalesce(reason,'scheduled'),'next_at',candidate); end if;
  return '{}'::jsonb;
end;
$$;

create function public.defer_campaign_dispatch_job(p_job_id uuid, p_eligibility jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare j public.campaign_dispatch_jobs; terminal text := p_eligibility->>'terminal';
begin
  select * into strict j from public.campaign_dispatch_jobs where id=p_job_id;
  if terminal is not null then
    update public.campaign_dispatch_jobs set phase=terminal,waiting_reason=null,lease_expires_at=null,
      publication_token=null,publication_expires_at=null,updated_at=clock_timestamp() where id=j.id;
    perform public.set_campaign_dispatch_delivery(j.delivery_id,terminal);
    return jsonb_build_object('phase',terminal);
  end if;
  update public.campaign_dispatch_jobs set phase='pending',waiting_reason=p_eligibility->>'reason',
    due_at=(p_eligibility->>'next_at')::timestamptz,publish_after=(p_eligibility->>'next_at')::timestamptz,
    lease_token=null,lease_expires_at=null,publication_token=null,publication_expires_at=null,updated_at=clock_timestamp() where id=j.id;
  perform public.set_campaign_dispatch_delivery(j.delivery_id,'queued');
  return jsonb_build_object('phase','deferred','reason',p_eligibility->>'reason','next_at',p_eligibility->>'next_at');
end;
$$;

create function public.get_campaign_sending_state(p_organization_id uuid,p_campaign_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if public.get_request_organization_role(p_organization_id) is null or public.get_request_organization_role(p_organization_id) not in ('owner','admin','member') then
    raise exception 'Campaign access required' using errcode='42501'; end if;
  if not exists(select 1 from public.campaigns where id=p_campaign_id and organization_id=p_organization_id) then
    raise exception 'Campaign not found' using errcode='P0002'; end if;
  select jsonb_build_object('waiting_count',count(*),'next_at',min(due_at),
    'reason',(array_agg(waiting_reason order by due_at,id))[1]) into result from public.campaign_dispatch_jobs
    where organization_id=p_organization_id and campaign_id=p_campaign_id and phase='pending' and waiting_reason is not null;
  return result;
end;
$$;

revoke all on function public.get_platform_campaign_policy(uuid), public.update_platform_campaign_policy(uuid,jsonb,bigint,uuid), public.get_campaign_sending_policy(uuid), public.get_campaign_sending_state(uuid,uuid) from public;
grant execute on function public.get_platform_campaign_policy(uuid), public.update_platform_campaign_policy(uuid,jsonb,bigint,uuid), public.get_campaign_sending_policy(uuid), public.get_campaign_sending_state(uuid,uuid) to authenticated;
grant execute on function public.get_campaign_sending_policy(uuid), public.get_campaign_sending_state(uuid,uuid) to anon;
revoke all on function public.campaign_dispatch_eligibility(uuid), public.defer_campaign_dispatch_job(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.campaign_dispatch_eligibility(uuid), public.defer_campaign_dispatch_job(uuid,jsonb) to service_role;

create function public.cancel_campaign(p_organization_id uuid,p_campaign_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare c public.campaigns;
begin
  if public.get_request_organization_role(p_organization_id) is null or public.get_request_organization_role(p_organization_id) not in ('owner','admin','member') then
    raise exception 'Campaign management access required' using errcode='42501'; end if;
  perform public.lock_campaign_sending_policy(p_organization_id);
  select * into c from public.campaigns where id=p_campaign_id and organization_id=p_organization_id for update;
  if not found then raise exception 'Campaign not found' using errcode='P0002'; end if;
  if c.dispatch_transport <> 'cloudamqp' or c.status='draft' then
    raise exception 'Only started CloudAMQP campaigns can be cancelled' using errcode='23514'; end if;
  if c.cancelled_at is null and c.queued_count+c.processing_count>0 then
    update public.campaigns set cancelled_at=clock_timestamp(),status=case when needs_review_count>0 then 'needs_review' else 'cancelled' end where id=c.id;
  end if;
  return jsonb_build_object('cancelled_at',(select cancelled_at from public.campaigns where id=c.id));
end;
$$;
revoke all on function public.cancel_campaign(uuid,uuid) from public;
grant execute on function public.cancel_campaign(uuid,uuid) to authenticated, anon;
