-- All mutations are private. Authenticated read RPCs authorize the parent campaign.
create function public.capture_campaign_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare kind text; reason text; delivery uuid; job uuid; attempt integer;
begin
  if tg_table_name='campaigns' then
    if tg_op='INSERT' or new.status=old.status then return new; end if;
    kind:=case when old.status='draft' then 'campaign_started'
      when new.status in ('completed','cancelled','expired') then 'dispatch_finished' else null end;
    reason:=new.status;
    if kind is not null then
      insert into public.campaign_activity(organization_id,campaign_id,event_type,reason_code)
      values(new.organization_id,new.id,kind,reason);
    end if;
    return new;
  elsif tg_table_name='campaign_dispatch_jobs' then
    if tg_op='INSERT' then return new; end if;
    delivery:=new.delivery_id; job:=new.id; attempt:=new.attempt_no;
    if new.waiting_reason is distinct from old.waiting_reason and new.waiting_reason is not null then
      kind:='waiting'; reason:=new.waiting_reason;
    elsif new.phase is distinct from old.phase then
      kind:=case new.phase when 'submitting' then 'submission_started'
        when 'retry_scheduled' then 'retry_scheduled' when 'needs_review' then 'needs_review'
        when 'failed' then 'dispatch_failed' else null end;
      reason:=new.error_code;
    end if;
  else
    if tg_op='INSERT' or new.status=old.status then return new; end if;
    delivery:=new.id; attempt:=new.attempts;
    -- Job transitions supply richer attempt evidence; delivery records acceptance once.
    if new.status='accepted' then kind:='accepted';
    elsif new.status='cancelled' then kind:='cancelled';
    elsif not exists(select 1 from public.campaign_dispatch_jobs where delivery_id=new.id) then
      kind:=case new.status when 'processing' then 'submission_started' when 'queued' then 'retry_scheduled'
        when 'failed' then 'dispatch_failed' when 'needs_review' then 'needs_review' else null end;
    end if;
  end if;
  if kind is not null then
    insert into public.campaign_activity(organization_id,campaign_id,delivery_id,job_id,attempt_no,event_type,reason_code)
    values(new.organization_id,new.campaign_id,delivery,job,attempt,kind,reason);
  end if;
  return new;
end;
$$;
revoke all on function public.capture_campaign_activity() from public,anon,authenticated;
create trigger capture_campaign_activity after update on public.campaigns for each row execute function public.capture_campaign_activity();
create trigger capture_campaign_delivery_activity after update on public.campaign_deliveries for each row execute function public.capture_campaign_activity();
create trigger capture_campaign_job_activity after update on public.campaign_dispatch_jobs for each row execute function public.capture_campaign_activity();

create function public.apply_campaign_receipt(p_receipt_id bigint) returns boolean
language plpgsql security definer set search_path='' as $$
declare r public.campaign_receipt_inbox; d public.campaign_deliveries; j public.campaign_dispatch_jobs;
  c public.campaigns; candidate uuid; inserted boolean; evidence jsonb;
begin
  select * into r from public.campaign_receipt_inbox where id=p_receipt_id;
  if not found then return false; end if;
  if r.processed_at is not null then return true; end if;
  perform public.lock_campaign_sending_policy(r.organization_id);
  -- Identify only; locks below follow the existing organization -> campaign -> job order.
  select cd.id into candidate from public.campaign_deliveries cd join public.campaigns cc on cc.id=cd.campaign_id
    where cd.organization_id=r.organization_id and cc.organization_address=r.organization_address
      and cd.external_id=r.external_id;
  if candidate is null and r.correlation ~ '^campaign:job:[0-9a-f-]{36}$' then
    select jj.delivery_id into candidate from public.campaign_dispatch_jobs jj join public.campaigns cc on cc.id=jj.campaign_id
    where jj.id::text=substr(r.correlation,14) and jj.organization_id=r.organization_id
      and cc.organization_address=r.organization_address and jj.send_started_at is not null
      and jj.phase in ('submitting','needs_review','accepted')
      and (jj.external_id is null or jj.external_id=r.external_id);
  elsif candidate is null and r.correlation ~ '^campaign:legacy:[0-9a-f-]{36}:[1-3]$' then
    select cd.id into candidate from public.campaign_deliveries cd join public.campaigns cc on cc.id=cd.campaign_id
    where cd.id::text=split_part(r.correlation,':',3) and cd.organization_id=r.organization_id
      and cc.organization_address=r.organization_address and cc.dispatch_transport='postgres'
      and cd.attempts=split_part(r.correlation,':',4)::integer and cd.status in ('processing','accepted')
      and (cd.external_id is null or cd.external_id=r.external_id);
  end if;
  if candidate is null then
    -- A real chat send may have been persisted after its receipt arrived.
    update public.messages m set status=coalesce(m.status,'{}'::jsonb)||jsonb_build_object(r.receipt_type,r.provider_at)
      where m.organization_id=r.organization_id and m.organization_address=r.organization_address
        and m.service='whatsapp' and m.direction='outgoing' and m.external_id=r.external_id
        and not(coalesce(m.status,'{}'::jsonb) ? r.receipt_type);
    if found or exists(select 1 from public.messages m where m.organization_id=r.organization_id
      and m.organization_address=r.organization_address and m.service='whatsapp' and m.direction='outgoing' and m.external_id=r.external_id) then
      update public.campaign_receipt_inbox set processed_at=clock_timestamp() where id=r.id; return true;
    end if;
    update public.campaign_receipt_inbox set next_check_at=clock_timestamp()+interval '5 minutes' where id=r.id;
    return false;
  end if;
  select * into d from public.campaign_deliveries where id=candidate;
  perform public.lock_campaign_sending_policy(r.organization_id);
  select * into strict c from public.campaigns where id=d.campaign_id for update;
  select * into j from public.campaign_dispatch_jobs where delivery_id=d.id
    and (external_id=r.external_id or (r.correlation='campaign:job:'||id::text and send_started_at is not null)) for update;
  select * into strict d from public.campaign_deliveries where id=candidate for update;
  select * into strict r from public.campaign_receipt_inbox where id=p_receipt_id for update;
  if r.processed_at is not null then return true; end if;
  if d.external_id is null then
    if j.id is not null and j.phase in ('submitting','needs_review') then
      perform public.finish_campaign_dispatch_job(j.id,j.lease_token,'accepted',r.external_id);
    elsif c.dispatch_transport='postgres' and d.status='processing' then
      perform public.record_campaign_delivery_result(d.id,r.external_id);
    else return false; end if;
  elsif d.external_id<>r.external_id then return false;
  end if;
  insert into public.campaign_activity(organization_id,campaign_id,delivery_id,job_id,attempt_no,event_type,reason_code,provider_at,recorded_at,deduplication_key)
    values(r.organization_id,d.campaign_id,d.id,j.id,coalesce(j.attempt_no,d.attempts),r.receipt_type,
      r.error_code,r.provider_at,r.recorded_at,'receipt:'||r.id) on conflict(deduplication_key) do nothing;
  inserted:=found;
  if inserted then
    insert into public.campaign_delivery_receipts(delivery_id,organization_id,campaign_id,sent_at,delivered_at,read_at,failed_at,failure_code)
    values(d.id,d.organization_id,d.campaign_id,
      case when r.receipt_type='sent' then r.provider_at end,
      case when r.receipt_type='delivered' then r.provider_at end,
      case when r.receipt_type='read' then r.provider_at end,
      case when r.receipt_type='failed' then r.provider_at end,r.error_code)
    on conflict(delivery_id) do update set
      sent_at=least(campaign_delivery_receipts.sent_at,excluded.sent_at),
      delivered_at=least(campaign_delivery_receipts.delivered_at,excluded.delivered_at),
      read_at=least(campaign_delivery_receipts.read_at,excluded.read_at),
      failed_at=least(campaign_delivery_receipts.failed_at,excluded.failed_at),
      failure_code=coalesce(campaign_delivery_receipts.failure_code,excluded.failure_code);
  end if;
  update public.campaign_receipt_inbox set processed_at=clock_timestamp() where id=r.id;
  return true;
end;
$$;
revoke all on function public.apply_campaign_receipt(bigint) from public,anon,authenticated;
grant execute on function public.apply_campaign_receipt(bigint) to service_role;

-- Returns false only for an existing genuine chat message. Everything else is durable.
create function public.ingest_campaign_receipt(p_organization_id uuid,p_organization_address text,p_external_id text,
  p_receipt_type text,p_provider_at timestamptz,p_correlation text default null,p_error_code text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare receipt bigint;
begin
  perform public.lock_campaign_sending_policy(p_organization_id);
  if not exists(select 1 from public.organizations_addresses where organization_id=p_organization_id
    and address=p_organization_address and service='whatsapp') then raise exception 'Unknown receipt account'; end if;
  if not exists(select 1 from public.campaign_deliveries where organization_id=p_organization_id and external_id=p_external_id)
    and exists(select 1 from public.messages where organization_id=p_organization_id and organization_address=p_organization_address
      and service='whatsapp' and direction='outgoing' and external_id=p_external_id) then return false; end if;
  insert into public.campaign_receipt_inbox(organization_id,organization_address,external_id,receipt_type,provider_at,correlation,error_code)
    values(p_organization_id,p_organization_address,p_external_id,p_receipt_type,p_provider_at,
      case when p_correlation ~ '^campaign:(job|legacy):[0-9a-f-]{36}(:[1-3])?$' then p_correlation end,p_error_code)
    on conflict(organization_id,organization_address,external_id,receipt_type,provider_at) do update
      set correlation=coalesce(campaign_receipt_inbox.correlation,excluded.correlation)
    returning id into receipt;
  perform public.apply_campaign_receipt(receipt);
  return true;
end;
$$;
revoke all on function public.ingest_campaign_receipt(uuid,text,text,text,timestamptz,text,text) from public,anon,authenticated;
grant execute on function public.ingest_campaign_receipt(uuid,text,text,text,timestamptz,text,text) to service_role;

create function public.reconcile_campaign_receipts(p_limit integer default 100) returns integer
language plpgsql security definer set search_path='' as $$
declare candidate record; processed integer:=0;
begin
  -- Do not lock receipt rows ahead of the parent campaign/job locks.
  for candidate in select id from public.campaign_receipt_inbox where processed_at is null and next_check_at<=clock_timestamp()
    order by next_check_at,id limit least(greatest(coalesce(p_limit,100),1),500) loop
    if public.apply_campaign_receipt(candidate.id) then processed:=processed+1; end if;
  end loop;
  return processed;
end;
$$;
revoke all on function public.reconcile_campaign_receipts(integer) from public,anon,authenticated;
grant execute on function public.reconcile_campaign_receipts(integer) to service_role;

create function public.get_campaign_receipt_summary(p_organization_id uuid,p_campaign_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not (p_organization_id in(select public.get_authorized_orgs_by_roles(array['owner','admin','member']::public.role[]))) then
    raise exception 'organization is not accessible' using errcode='42501'; end if;
  if not exists(select 1 from public.campaigns where id=p_campaign_id and organization_id=p_organization_id) then
    raise exception 'campaign not found' using errcode='P0002'; end if;
  select jsonb_build_object('sent',count(*) filter(where sent_at is not null or delivered_at is not null or read_at is not null),
    'delivered',count(*) filter(where delivered_at is not null or read_at is not null),'read',count(*) filter(where read_at is not null),
    'delivery_failed',count(*) filter(where failed_at is not null and delivered_at is null and read_at is null)) into result
    from public.campaign_delivery_receipts where organization_id=p_organization_id and campaign_id=p_campaign_id;
  return result;
end;
$$;
revoke all on function public.get_campaign_receipt_summary(uuid,uuid) from public;
grant execute on function public.get_campaign_receipt_summary(uuid,uuid) to authenticated,anon;

create function public.list_campaign_activity_page(p_organization_id uuid,p_campaign_id uuid,p_page integer default 1,
  p_page_size integer default 10) returns table(id bigint,delivery_id uuid,job_id uuid,attempt_no integer,
    event_type text,reason_code text,provider_at timestamptz,recorded_at timestamptz,total_count bigint)
language plpgsql stable security definer set search_path='' as $$
begin
  perform public.get_campaign_receipt_summary(p_organization_id,p_campaign_id);
  return query select a.id,a.delivery_id,a.job_id,a.attempt_no,a.event_type,a.reason_code,a.provider_at,a.recorded_at,count(*) over()
    from public.campaign_activity a where a.organization_id=p_organization_id and a.campaign_id=p_campaign_id
    order by a.recorded_at desc,a.id desc limit least(greatest(coalesce(p_page_size,10),1),50)
    offset (greatest(coalesce(p_page,1),1)::bigint-1)*least(greatest(coalesce(p_page_size,10),1),50);
end;
$$;
revoke all on function public.list_campaign_activity_page(uuid,uuid,integer,integer) from public;
grant execute on function public.list_campaign_activity_page(uuid,uuid,integer,integer) to authenticated,anon;
