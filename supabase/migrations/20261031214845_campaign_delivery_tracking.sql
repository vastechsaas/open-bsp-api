
  create table "public"."campaign_activity" (
    "id" bigint generated always as identity not null,
    "organization_id" uuid not null,
    "campaign_id" uuid not null,
    "delivery_id" uuid,
    "job_id" uuid,
    "attempt_no" integer,
    "event_type" text not null,
    "reason_code" text,
    "provider_at" timestamp with time zone,
    "recorded_at" timestamp with time zone not null default clock_timestamp(),
    "deduplication_key" text
      );


alter table "public"."campaign_activity" enable row level security;


  create table "public"."campaign_delivery_receipts" (
    "delivery_id" uuid not null,
    "organization_id" uuid not null,
    "campaign_id" uuid not null,
    "sent_at" timestamp with time zone,
    "delivered_at" timestamp with time zone,
    "read_at" timestamp with time zone,
    "failed_at" timestamp with time zone,
    "failure_code" text
      );


alter table "public"."campaign_delivery_receipts" enable row level security;


  create table "public"."campaign_receipt_inbox" (
    "id" bigint generated always as identity not null,
    "organization_id" uuid not null,
    "organization_address" text not null,
    "external_id" text not null,
    "receipt_type" text not null,
    "provider_at" timestamp with time zone not null,
    "recorded_at" timestamp with time zone not null default clock_timestamp(),
    "correlation" text,
    "error_code" text,
    "processed_at" timestamp with time zone,
    "next_check_at" timestamp with time zone not null default clock_timestamp()
      );


alter table "public"."campaign_receipt_inbox" enable row level security;

CREATE UNIQUE INDEX campaign_activity_deduplication_key_key ON public.campaign_activity USING btree (deduplication_key);

CREATE INDEX campaign_activity_page_idx ON public.campaign_activity USING btree (organization_id, campaign_id, recorded_at DESC, id DESC);

CREATE UNIQUE INDEX campaign_activity_pkey ON public.campaign_activity USING btree (id);

CREATE INDEX campaign_delivery_receipts_campaign_idx ON public.campaign_delivery_receipts USING btree (organization_id, campaign_id);

CREATE UNIQUE INDEX campaign_delivery_receipts_pkey ON public.campaign_delivery_receipts USING btree (delivery_id);

CREATE UNIQUE INDEX campaign_receipt_inbox_organization_id_organization_address_key ON public.campaign_receipt_inbox USING btree (organization_id, organization_address, external_id, receipt_type, provider_at);

CREATE INDEX campaign_receipt_inbox_pending_idx ON public.campaign_receipt_inbox USING btree (next_check_at, id) WHERE (processed_at IS NULL);

CREATE UNIQUE INDEX campaign_receipt_inbox_pkey ON public.campaign_receipt_inbox USING btree (id);

alter table "public"."campaign_activity" add constraint "campaign_activity_pkey" PRIMARY KEY using index "campaign_activity_pkey";

alter table "public"."campaign_delivery_receipts" add constraint "campaign_delivery_receipts_pkey" PRIMARY KEY using index "campaign_delivery_receipts_pkey";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_pkey" PRIMARY KEY using index "campaign_receipt_inbox_pkey";

alter table "public"."campaign_activity" add constraint "campaign_activity_deduplication_key_key" UNIQUE using index "campaign_activity_deduplication_key_key";

alter table "public"."campaign_activity" add constraint "campaign_activity_organization_id_campaign_id_delivery_id_fkey" FOREIGN KEY (organization_id, campaign_id, delivery_id) REFERENCES public.campaign_deliveries(organization_id, campaign_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_activity" validate constraint "campaign_activity_organization_id_campaign_id_delivery_id_fkey";

alter table "public"."campaign_activity" add constraint "campaign_activity_organization_id_campaign_id_fkey" FOREIGN KEY (organization_id, campaign_id) REFERENCES public.campaigns(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_activity" validate constraint "campaign_activity_organization_id_campaign_id_fkey";

alter table "public"."campaign_delivery_receipts" add constraint "campaign_delivery_receipts_organization_id_campaign_id_del_fkey" FOREIGN KEY (organization_id, campaign_id, delivery_id) REFERENCES public.campaign_deliveries(organization_id, campaign_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_delivery_receipts" validate constraint "campaign_delivery_receipts_organization_id_campaign_id_del_fkey";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_correlation_check" CHECK ((length(correlation) <= 128)) not valid;

alter table "public"."campaign_receipt_inbox" validate constraint "campaign_receipt_inbox_correlation_check";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_error_code_check" CHECK ((error_code ~ '^[a-zA-Z0-9_.:-]{1,100}$'::text)) not valid;

alter table "public"."campaign_receipt_inbox" validate constraint "campaign_receipt_inbox_error_code_check";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_external_id_check" CHECK (((length(external_id) >= 1) AND (length(external_id) <= 512))) not valid;

alter table "public"."campaign_receipt_inbox" validate constraint "campaign_receipt_inbox_external_id_check";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_receipt_inbox" validate constraint "campaign_receipt_inbox_organization_id_fkey";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_organization_id_organization_address_key" UNIQUE using index "campaign_receipt_inbox_organization_id_organization_address_key";

alter table "public"."campaign_receipt_inbox" add constraint "campaign_receipt_inbox_receipt_type_check" CHECK ((receipt_type = ANY (ARRAY['sent'::text, 'delivered'::text, 'read'::text, 'failed'::text]))) not valid;

alter table "public"."campaign_receipt_inbox" validate constraint "campaign_receipt_inbox_receipt_type_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.apply_campaign_receipt(p_receipt_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.capture_campaign_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_receipt_summary(p_organization_id uuid, p_campaign_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_campaign_receipt(p_organization_id uuid, p_organization_address text, p_external_id text, p_receipt_type text, p_provider_at timestamp with time zone, p_correlation text DEFAULT NULL::text, p_error_code text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.list_campaign_activity_page(p_organization_id uuid, p_campaign_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10)
 RETURNS TABLE(id bigint, delivery_id uuid, job_id uuid, attempt_no integer, event_type text, reason_code text, provider_at timestamp with time zone, recorded_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.get_campaign_receipt_summary(p_organization_id,p_campaign_id);
  return query select a.id,a.delivery_id,a.job_id,a.attempt_no,a.event_type,a.reason_code,a.provider_at,a.recorded_at,count(*) over()
    from public.campaign_activity a where a.organization_id=p_organization_id and a.campaign_id=p_campaign_id
    order by a.recorded_at desc,a.id desc limit least(greatest(coalesce(p_page_size,10),1),50)
    offset (greatest(coalesce(p_page,1),1)::bigint-1)*least(greatest(coalesce(p_page_size,10),1),50);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reconcile_campaign_receipts(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; processed integer:=0;
begin
  -- Do not lock receipt rows ahead of the parent campaign/job locks.
  for candidate in select id from public.campaign_receipt_inbox where processed_at is null and next_check_at<=clock_timestamp()
    order by next_check_at,id limit least(greatest(coalesce(p_limit,100),1),500) loop
    if public.apply_campaign_receipt(candidate.id) then processed:=processed+1; end if;
  end loop;
  return processed;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_campaign_delivery_result(p_delivery_id uuid, p_external_id text DEFAULT NULL::text, p_error jsonb DEFAULT NULL::jsonb, p_retryable boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  delivery public.campaign_deliveries;
  target_campaign public.campaigns;
  target_campaign_id uuid;
  final_status text;
begin
  select d.campaign_id into target_campaign_id
  from public.campaign_deliveries d
  where d.id = p_delivery_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign delivery not found';
  end if;

  select * into target_campaign
  from public.campaigns c
  where c.id = target_campaign_id
  for update;

  select * into delivery
  from public.campaign_deliveries d
  where d.id = p_delivery_id
  for update;

  -- A signed receipt may have reconciled this exact acceptance before the HTTP result.
  if delivery.status = 'accepted' and delivery.external_id = p_external_id then
    return 'accepted';
  end if;

  if delivery.status <> 'processing' then
    raise exception using
      errcode = '23514',
      message = 'campaign delivery is not processing';
  end if;

  if p_external_id is not null then
    final_status := 'accepted';

    update public.campaign_deliveries
    set
      status = final_status,
      external_id = p_external_id,
      error = null
    where id = p_delivery_id;

    update public.campaigns
    set
      processing_count = processing_count - 1,
      accepted_count = accepted_count + 1
    where id = target_campaign_id
    returning * into target_campaign;
  elsif p_retryable and delivery.attempts < 3 then
    final_status := 'queued';

    update public.campaign_deliveries
    set
      status = final_status,
      error = p_error
    where id = p_delivery_id;

    update public.campaigns
    set
      processing_count = processing_count - 1,
      queued_count = queued_count + 1
    where id = target_campaign_id
    returning * into target_campaign;
  else
    final_status := 'failed';

    update public.campaign_deliveries
    set
      status = final_status,
      error = p_error
    where id = p_delivery_id;

    update public.campaigns
    set
      processing_count = processing_count - 1,
      failed_count = failed_count + 1
    where id = target_campaign_id
    returning * into target_campaign;
  end if;

  if target_campaign.queued_count = 0
    and target_campaign.processing_count = 0
  then
    update public.campaigns
    set status = 'completed'
    where id = target_campaign_id;
  end if;

  return final_status;
end;
$function$
;

grant delete on table "public"."campaign_activity" to "service_role";

grant insert on table "public"."campaign_activity" to "service_role";

grant references on table "public"."campaign_activity" to "service_role";

grant select on table "public"."campaign_activity" to "service_role";

grant trigger on table "public"."campaign_activity" to "service_role";

grant truncate on table "public"."campaign_activity" to "service_role";

grant update on table "public"."campaign_activity" to "service_role";

grant delete on table "public"."campaign_delivery_receipts" to "service_role";

grant insert on table "public"."campaign_delivery_receipts" to "service_role";

grant references on table "public"."campaign_delivery_receipts" to "service_role";

grant select on table "public"."campaign_delivery_receipts" to "service_role";

grant trigger on table "public"."campaign_delivery_receipts" to "service_role";

grant truncate on table "public"."campaign_delivery_receipts" to "service_role";

grant update on table "public"."campaign_delivery_receipts" to "service_role";

grant delete on table "public"."campaign_receipt_inbox" to "service_role";

grant insert on table "public"."campaign_receipt_inbox" to "service_role";

grant references on table "public"."campaign_receipt_inbox" to "service_role";

grant select on table "public"."campaign_receipt_inbox" to "service_role";

grant trigger on table "public"."campaign_receipt_inbox" to "service_role";

grant truncate on table "public"."campaign_receipt_inbox" to "service_role";

grant update on table "public"."campaign_receipt_inbox" to "service_role";

CREATE TRIGGER capture_campaign_delivery_activity AFTER UPDATE ON public.campaign_deliveries FOR EACH ROW EXECUTE FUNCTION public.capture_campaign_activity();

CREATE TRIGGER capture_campaign_job_activity AFTER UPDATE ON public.campaign_dispatch_jobs FOR EACH ROW EXECUTE FUNCTION public.capture_campaign_activity();

CREATE TRIGGER capture_campaign_activity AFTER UPDATE ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.capture_campaign_activity();

-- Explicit ACLs: the schema differ does not preserve function/default grants.
revoke all on public.campaign_activity,public.campaign_delivery_receipts,public.campaign_receipt_inbox from public,anon,authenticated;
grant all on public.campaign_activity,public.campaign_delivery_receipts,public.campaign_receipt_inbox to service_role;
grant usage,select on sequence public.campaign_activity_id_seq,public.campaign_receipt_inbox_id_seq to service_role;
revoke all on function public.capture_campaign_activity() from public,anon,authenticated;
revoke all on function public.apply_campaign_receipt(bigint), public.ingest_campaign_receipt(uuid,text,text,text,timestamptz,text,text),public.reconcile_campaign_receipts(integer) from public,anon,authenticated;
grant execute on function public.apply_campaign_receipt(bigint),public.ingest_campaign_receipt(uuid,text,text,text,timestamptz,text,text),public.reconcile_campaign_receipts(integer) to service_role;
revoke all on function public.get_campaign_receipt_summary(uuid,uuid),public.list_campaign_activity_page(uuid,uuid,integer,integer) from public;
grant execute on function public.get_campaign_receipt_summary(uuid,uuid),public.list_campaign_activity_page(uuid,uuid,integer,integer) to authenticated,anon;
revoke all on function public.record_campaign_delivery_result(uuid,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.record_campaign_delivery_result(uuid,text,jsonb,boolean) to service_role;



