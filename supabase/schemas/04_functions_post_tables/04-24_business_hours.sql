-- Human-support schedules only: never disable chatbot ingestion or an existing
-- human-owned conversation. Unconfigured/disabled schedules preserve old behavior.
create function public.validate_business_hours_schedule(p_schedule jsonb) returns void
language plpgsql stable set search_path = '' as $$
declare d text; r jsonb; h jsonb; dates text[] := '{}';
begin
  if jsonb_typeof(p_schedule) is distinct from 'object'
    or p_schedule->>'mode' not in ('all_days','per_day')
    or p_schedule->>'mode' is null
    or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_schedule->>'timezone')
    or (p_schedule ? 'enabled' and jsonb_typeof(p_schedule->'enabled') <> 'boolean')
    or jsonb_typeof(p_schedule->'per_day') is distinct from 'object' then
    raise exception 'Invalid business hours mode or time zone' using errcode='22023';
  end if;
  foreach d in array array['all_days','monday','tuesday','wednesday','thursday','friday','saturday','sunday'] loop
    r := case when d='all_days' then p_schedule->d else p_schedule->'per_day'->d end;
    if jsonb_typeof(r) is distinct from 'object'
      or coalesce(r->>'start_time','') !~ '^([01][0-9]|2[0-3]):(00|15|30|45)$'
      or coalesce(r->>'end_time','') !~ '^(([01][0-9]|2[0-3]):(00|15|30|45)|24:00)$'
      or (d<>'all_days' and jsonb_typeof(r->'enabled') is distinct from 'boolean') then
      raise exception 'Invalid business hours time range: %',d using errcode='22023';
    end if;
    if ((d='all_days' and p_schedule->>'mode'='all_days')
      or (d<>'all_days' and p_schedule->>'mode'='per_day' and (r->>'enabled')::boolean))
      and r->>'end_time' <= r->>'start_time' then
      raise exception 'End time must be after start time: %',d using errcode='22023';
    end if;
  end loop;
  if p_schedule ? 'holidays' then
    if jsonb_typeof(p_schedule->'holidays') <> 'array' or jsonb_array_length(p_schedule->'holidays') > 366 then
      raise exception 'At most 366 holiday overrides are allowed' using errcode='22023'; end if;
    for h in select value from jsonb_array_elements(p_schedule->'holidays') loop
      if coalesce(h->>'date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or jsonb_typeof(h->'closed') is distinct from 'boolean' then
        raise exception 'Invalid holiday date or closed flag' using errcode='22023'; end if;
      perform (h->>'date')::date;
      if h->>'date'=any(dates) then raise exception 'Duplicate holiday date' using errcode='22023'; end if;
      dates := array_append(dates,h->>'date');
      if not (h->>'closed')::boolean and (
        coalesce(h->>'start_time','') !~ '^([01][0-9]|2[0-3]):(00|15|30|45)$'
        or coalesce(h->>'end_time','') !~ '^(([01][0-9]|2[0-3]):(00|15|30|45)|24:00)$'
        or h->>'end_time' <= h->>'start_time') then
        raise exception 'Invalid holiday opening hours' using errcode='22023'; end if;
    end loop;
  end if;
end;
$$;

create function public.guard_business_hours_settings() returns trigger
language plpgsql security definer set search_path='' as $$
declare s jsonb := new.extra->'business_hours'; q record; field text;
begin
  if s is null or s='null'::jsonb then return new; end if;
  if tg_op='UPDATE' and s is not distinct from old.extra->'business_hours' then return new; end if;
  perform public.validate_business_hours_schedule(s);
  if s ? 'queue_overrides' then
    if jsonb_typeof(s->'queue_overrides') <> 'object' then
      raise exception 'Queue overrides must be an object' using errcode='22023'; end if;
    for q in select * from jsonb_each(s->'queue_overrides') loop
      -- JSON merge uses null tombstones to remove an override atomically.
      if q.value='null'::jsonb then continue; end if;
      if not exists(select 1 from public.routing_queues where organization_id=new.id and id=q.key::uuid) then
        raise exception 'Queue override must belong to a tenant queue' using errcode='22023'; end if;
      if q.value ? 'queue_overrides' then raise exception 'Nested queue overrides are unsupported' using errcode='22023'; end if;
      perform public.validate_business_hours_schedule(q.value);
    end loop;
  end if;
  foreach field in array array['outside_hours_message','no_agents_message'] loop
    if s ? field and (jsonb_typeof(s->field)<>'string' or length(btrim(s->>field)) not between 1 and 4096) then
      raise exception 'Unavailable support messages must contain 1 to 4096 characters' using errcode='22023'; end if;
  end loop;
  return new;
end;
$$;
-- Runs after set_extra so partial patches are validated after the JSON merge.
create trigger zz_validate_business_hours before insert or update of extra on public.organizations
for each row execute function public.guard_business_hours_settings();

create function public.business_hours_schedule_open(p_schedule jsonb, p_at timestamptz) returns boolean
language plpgsql stable set search_path='' as $$
declare local_at timestamp; r jsonb; day_name text;
begin
  if p_schedule is null or p_schedule='null'::jsonb or p_schedule->>'enabled'='false' then return true; end if;
  local_at := p_at at time zone (p_schedule->>'timezone');
  select value into r from jsonb_array_elements(coalesce(p_schedule->'holidays','[]'::jsonb))
    where value->>'date'=to_char(local_at,'YYYY-MM-DD');
  if found then
    if (r->>'closed')::boolean then return false; end if;
  elsif p_schedule->>'mode'='all_days' then r := p_schedule->'all_days';
  else
    day_name := (array['monday','tuesday','wednesday','thursday','friday','saturday','sunday'])[extract(isodow from local_at)::integer];
    r := p_schedule->'per_day'->day_name;
    if r->>'enabled' is distinct from 'true' then return false; end if;
  end if;
  -- Lexical HH:mm comparisons keep 24:00 as the next-day boundary.
  return coalesce(to_char(local_at,'HH24:MI') >= r->>'start_time'
    and to_char(local_at,'HH24:MI') < r->>'end_time', false);
exception when others then return false; -- malformed legacy configuration fails closed
end;
$$;

create function public.business_hours_status(p_organization_id uuid, p_queue_id uuid default null,
  p_agent_id uuid default null, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare root jsonb; schedule jsonb; available_count integer; is_open boolean; enabled boolean;
begin
  select extra->'business_hours' into root from public.organizations where id=p_organization_id;
  enabled := root is not null and root<>'null'::jsonb and root->>'enabled' is distinct from 'false';
  schedule := case when enabled and root->'queue_overrides'->p_queue_id::text is not null
    and root->'queue_overrides'->p_queue_id::text<>'null'::jsonb then root->'queue_overrides'->p_queue_id::text else root end;
  is_open := not enabled or public.business_hours_schedule_open(schedule,p_at);
  select count(*) into available_count from public.agents a
    join public.agent_assignment_presence p on p.organization_id=a.organization_id and p.agent_id=a.id
    where a.organization_id=p_organization_id and not a.ai and a.user_id is not null
      and a.extra->>'role'='agent' and coalesce(a.extra->'invitation'->>'status','accepted')='accepted'
      and p.available and p.last_heartbeat_at >= p_at-interval '2 minutes'
      and (p_agent_id is null or a.id=p_agent_id)
      and (p_queue_id is null or exists(select 1 from public.routing_queue_members m
        join public.routing_queues q on q.id=m.routing_queue_id and q.organization_id=m.organization_id and q.status='active'
        where m.organization_id=p_organization_id and m.agent_id=a.id and m.routing_queue_id=p_queue_id));
  return jsonb_build_object('configured',enabled,'open',is_open,'available_agents',available_count,
    'timezone',schedule->>'timezone','reason',case when not public.is_organization_active(p_organization_id) then 'suspended'
      when not is_open then 'outside_hours' when available_count=0 then 'no_agents' else 'available' end);
end;
$$;

create function public.get_business_hours_status(p_organization_id uuid, p_queue_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if public.get_request_organization_role(p_organization_id) is null then
    raise exception 'Tenant membership required' using errcode='42501'; end if;
  if p_queue_id is not null and not exists(select 1 from public.routing_queues where organization_id=p_organization_id and id=p_queue_id) then
    raise exception 'Tenant queue required' using errcode='42501'; end if;
  return public.business_hours_status(p_organization_id,p_queue_id);
end;
$$;

create function public.notify_support_unavailability(p_conversation_id uuid, p_request_id text,
  p_agent_id uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations; availability jsonb; root jsonb; body text; latest_inbound timestamptz;
begin
  select * into c from public.conversations where id=p_conversation_id for update;
  if not found or c.status<>'active' or not public.is_organization_active(c.organization_id)
    or exists(select 1 from public.contacts_addresses where organization_id=c.organization_id
      and address=c.contact_address and status='blocked') then return; end if;
  availability := public.business_hours_status(c.organization_id,c.routing_queue_id,p_agent_id);
  if not (availability->>'configured')::boolean or availability->>'reason' not in ('outside_hours','no_agents') then return; end if;
  select extra->'business_hours' into root from public.organizations where id=c.organization_id;
  body := case when availability->>'reason'='outside_hours' then
    coalesce(root->>'outside_hours_message','Our support team is currently outside business hours. Your request is queued and will be reviewed when support is available.')
    else coalesce(root->>'no_agents_message','All support agents are currently unavailable. Your request is queued for the next available support agent.') end;
  -- Do not originate a free-form notice outside the customer service window.
  select max(timestamp) into latest_inbound from public.messages where conversation_id=c.id and direction='incoming' and content<>'{}'::jsonb;
  if latest_inbound is null or latest_inbound < now()-interval '24 hours' then return; end if;
  insert into public.messages(id,organization_id,conversation_id,direction,service,organization_address,contact_address,
    group_address,content,timestamp)
  values(md5('support-availability:'||c.id::text||':'||p_request_id)::uuid,c.organization_id,c.id,
    'outgoing',c.service,c.organization_address,c.contact_address,c.group_address,
    jsonb_build_object('version','1','type','text','kind','text','text',body),now())
  on conflict(id) do nothing;
end;
$$;

revoke all on function public.validate_business_hours_schedule(jsonb) from public,anon,authenticated;
revoke all on function public.guard_business_hours_settings() from public,anon,authenticated;
revoke all on function public.business_hours_schedule_open(jsonb,timestamptz) from public,anon,authenticated;
revoke all on function public.business_hours_status(uuid,uuid,uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.notify_support_unavailability(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.get_business_hours_status(uuid,uuid) from public,anon;
grant execute on function public.get_business_hours_status(uuid,uuid) to authenticated,service_role;
grant execute on function public.business_hours_status(uuid,uuid,uuid,timestamptz) to service_role;
