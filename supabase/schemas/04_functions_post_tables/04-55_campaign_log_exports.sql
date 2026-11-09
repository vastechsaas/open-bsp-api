create function public.authorize_campaign_log_export(p_org uuid,p_campaign uuid,p_owner uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.agents a
    join public.organization_lifecycle l on l.organization_id=a.organization_id and l.status='active'
    join public.campaigns c on c.organization_id=a.organization_id and c.id=p_campaign and c.status='completed'
    where a.organization_id=p_org and a.user_id=p_owner and a.extra->>'role'='owner'
      and (a.extra->'invitation' is null or a.extra->'invitation'->>'status'='accepted'));
$$;
revoke all on function public.authorize_campaign_log_export(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.authorize_campaign_log_export(uuid,uuid,uuid) to service_role;

create function public.campaign_log_export_info(p_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',id,'state',state,'snapshot_at',snapshot_at,'expires_at',expires_at,
    'timezone',timezone,'row_count',row_count,'processed_count',processed_count)
  from public.campaign_log_exports where id=p_id;
$$;
revoke all on function public.campaign_log_export_info(uuid) from public,anon,authenticated;
grant execute on function public.campaign_log_export_info(uuid) to service_role;

create function public.request_campaign_log_export(p_organization_id uuid,p_campaign_id uuid,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.campaigns; e public.campaign_log_exports; profile jsonb; count_rows bigint;
begin
  if auth.uid() is null or not public.authorize_campaign_log_export(p_organization_id,p_campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Completed campaign and organization Owner access required';
  end if;
  if p_request_id is null then raise exception 'Request ID required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('campaign-export:'||p_campaign_id::text||auth.uid()::text,0));
  select * into e from public.campaign_log_exports where owner_id=auth.uid() and request_id=p_request_id;
  if found then
    if e.organization_id<>p_organization_id or e.campaign_id<>p_campaign_id then raise exception 'Request ID conflict'; end if;
    if e.expires_at<=clock_timestamp() then raise exception 'Export expired; use a new request ID'; end if;
    return public.campaign_log_export_info(e.id);
  end if;
  select * into e from public.campaign_log_exports where organization_id=p_organization_id
    and campaign_id=p_campaign_id and owner_id=auth.uid() and expires_at>clock_timestamp()
    and state in ('queued','processing') order by snapshot_at desc limit 1;
  if found then return public.campaign_log_export_info(e.id); end if;
  select * into strict c from public.campaigns where organization_id=p_organization_id and id=p_campaign_id;
  select extra into profile from public.organizations_addresses where organization_id=p_organization_id
    and address=c.organization_address and service=c.service;
  insert into public.campaign_log_exports(organization_id,campaign_id,owner_id,request_id,timezone,template,mapping,sender_number,display_name)
  values(p_organization_id,c.id,auth.uid(),p_request_id,coalesce(c.schedule_timezone,'UTC'),c.template,c.template_variable_mapping,
    coalesce(profile->>'phone_number',''),coalesce(profile->>'verified_name','')) returning * into e;
  -- One statement/MVCC snapshot: later receipts cannot change a partially built export.
  insert into public.campaign_log_export_rows(export_id,ordinal,sent_at,recipient,recipient_name,variables,status)
  select e.id,row_number() over(order by d.id),coalesce(j.sent_at,a.sent_at),d.contact_address,d.name,d.variables,
    case when r.delivered_at is not null or r.read_at is not null then 'Delivered'
      when r.failed_at is not null or d.status='failed' then 'Not Delivered' else '' end
  from public.campaign_deliveries d
  left join public.campaign_delivery_receipts r on r.delivery_id=d.id
  left join lateral(select max(send_started_at) sent_at from public.campaign_dispatch_jobs where delivery_id=d.id) j on true
  left join lateral(select max(recorded_at) sent_at from public.campaign_activity
    where organization_id=p_organization_id and campaign_id=p_campaign_id and delivery_id=d.id and event_type='submission_started') a on true
  where d.organization_id=p_organization_id and d.campaign_id=p_campaign_id;
  get diagnostics count_rows=row_count;
  update public.campaign_log_exports set row_count=count_rows where id=e.id;
  return public.campaign_log_export_info(e.id);
end;
$$;
revoke all on function public.request_campaign_log_export(uuid,uuid,uuid) from public,anon;
grant execute on function public.request_campaign_log_export(uuid,uuid,uuid) to authenticated;

create function public.get_campaign_log_export(p_organization_id uuid,p_campaign_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.authorize_campaign_log_export(p_organization_id,p_campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Completed campaign and organization Owner access required'; end if;
  select public.campaign_log_export_info(id) into result from public.campaign_log_exports
    where organization_id=p_organization_id and campaign_id=p_campaign_id and owner_id=auth.uid()
      and expires_at>clock_timestamp() order by snapshot_at desc,id desc limit 1;
  return result;
end;
$$;
revoke all on function public.get_campaign_log_export(uuid,uuid) from public,anon;
grant execute on function public.get_campaign_log_export(uuid,uuid) to authenticated;

create function public.retry_campaign_log_export(p_export_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e public.campaign_log_exports;
begin
  select * into e from public.campaign_log_exports where id=p_export_id for update;
  if not found or auth.uid() is null or e.owner_id<>auth.uid()
    or not public.authorize_campaign_log_export(e.organization_id,e.campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Owner access required'; end if;
  if e.expires_at<=clock_timestamp() then raise exception 'Export expired'; end if;
  if e.state='failed' then
    update public.campaign_log_exports set state='queued',failures=0,lease_token=null,lease_until=null where id=e.id;
  end if;
  return public.campaign_log_export_info(e.id);
end;
$$;
revoke all on function public.retry_campaign_log_export(uuid) from public,anon;
grant execute on function public.retry_campaign_log_export(uuid) to authenticated;

-- A short-lived one-use ticket permits a native streaming browser download without
-- putting a session JWT in a URL or accumulating the entire CSV in JavaScript memory.
create function public.issue_campaign_log_download(p_export_id uuid) returns text
language plpgsql security definer set search_path='' as $$
declare e public.campaign_log_exports; ticket text;
begin
  select * into e from public.campaign_log_exports where id=p_export_id for update;
  if not found or auth.uid() is null or e.owner_id<>auth.uid()
    or not public.authorize_campaign_log_export(e.organization_id,e.campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Owner access required'; end if;
  if e.state<>'ready' or e.expires_at<=clock_timestamp() then raise exception 'Export unavailable'; end if;
  ticket:=encode(extensions.gen_random_bytes(32),'hex');
  update public.campaign_log_exports set ticket_hash=encode(extensions.digest(ticket,'sha256'),'hex'),
    ticket_until=clock_timestamp()+interval '1 minute' where id=e.id;
  return ticket;
end;
$$;
revoke all on function public.issue_campaign_log_download(uuid) from public,anon;
grant execute on function public.issue_campaign_log_download(uuid) to authenticated;

create function public.consume_campaign_log_download(p_ticket text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e public.campaign_log_exports;
begin
  if length(p_ticket)<>64 then return null; end if;
  select * into e from public.campaign_log_exports where ticket_hash=encode(extensions.digest(p_ticket,'sha256'),'hex') for update;
  if not found then return null; end if;
  update public.campaign_log_exports set ticket_hash=null,ticket_until=null where id=e.id;
  if e.state<>'ready' or e.expires_at<=clock_timestamp() or e.ticket_until<=clock_timestamp()
    or not public.authorize_campaign_log_export(e.organization_id,e.campaign_id,e.owner_id) then return null; end if;
  return public.campaign_log_export_info(e.id);
end;
$$;
revoke all on function public.consume_campaign_log_download(text) from public,anon,authenticated;
grant execute on function public.consume_campaign_log_download(text) to service_role;

create function public.claim_campaign_log_export() returns public.campaign_log_exports
language plpgsql security definer set search_path='' as $$
declare e public.campaign_log_exports;
begin
  select * into e from public.campaign_log_exports
    where expires_at>clock_timestamp() and (state='queued' or (state='processing' and lease_until<clock_timestamp()))
      and public.authorize_campaign_log_export(organization_id,campaign_id,owner_id)
    order by snapshot_at,id limit 1 for update skip locked;
  if not found then return null; end if;
  update public.campaign_log_exports set state='processing',lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '60 seconds'
    where id=e.id returning * into e;
  return e;
end;
$$;
revoke all on function public.claim_campaign_log_export() from public,anon,authenticated;
grant execute on function public.claim_campaign_log_export() to service_role;

create function public.finish_campaign_log_export_part(p_export_id uuid,p_token uuid,p_success boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare e public.campaign_log_exports; next_count bigint;
begin
  select * into e from public.campaign_log_exports where id=p_export_id for update;
  if not found or e.state<>'processing' or e.lease_token is distinct from p_token or e.lease_until<=clock_timestamp()
    or e.expires_at<=clock_timestamp() then return false; end if;
  if not p_success then
    update public.campaign_log_exports set failures=failures+1,state=case when failures>=2 then 'failed' else 'queued' end,
      lease_token=null,lease_until=null where id=e.id;
    return true;
  end if;
  next_count:=least(e.processed_count+100,e.row_count);
  if next_count>e.processed_count then
    insert into public.campaign_log_export_parts(export_id,part_no,path)
      values(e.id,e.processed_count/100,e.id::text||'/'||(e.processed_count/100)::text||'.csv') on conflict do nothing;
  end if;
  update public.campaign_log_exports set processed_count=next_count,
    state=case when next_count=e.row_count then 'ready' else 'queued' end,
    failures=0,lease_token=null,lease_until=null where id=e.id;
  return true;
end;
$$;
revoke all on function public.finish_campaign_log_export_part(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.finish_campaign_log_export_part(uuid,uuid,boolean) to service_role;

-- Also find files orphaned by campaign/organization deletion; no public Storage
-- policy is granted for this bucket, including to Owners.
create function public.campaign_log_export_cleanup_candidates() returns setof text
language sql stable security definer set search_path='' as $$
  select folder from (
    select id::text folder from public.campaign_log_exports where expires_at<=now()
    union
    select split_part(name,'/',1) from storage.objects o where bucket_id='campaign-log-exports'
      and not exists(select 1 from public.campaign_log_exports e where e.id::text=split_part(o.name,'/',1) and e.expires_at>now())
  ) candidates order by folder limit 5;
$$;
revoke all on function public.campaign_log_export_cleanup_candidates() from public,anon,authenticated;
grant execute on function public.campaign_log_export_cleanup_candidates() to service_role;
