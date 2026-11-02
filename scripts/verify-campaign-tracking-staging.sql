-- Synthetic, terminal-only UI fixture. No start_campaign, job claims or Meta calls.
-- Run only against acifbsuxmpdtlhbsvhlj after its protected pre-deployment backup.
begin;
do $$
declare org uuid; campaign uuid := '14114100-0000-4000-8000-000000000099';
  owner_agent uuid; owner_user uuid; delivery uuid; stamp timestamptz := date_trunc('second',clock_timestamp());
  n integer; events_before bigint; result jsonb;
begin
  select id into strict org from public.organizations where name='SCRUM-128 PSDF isolated sync test';
  if exists(select 1 from public.campaigns where id=campaign) then
    if not exists(select 1 from public.campaigns where id=campaign and organization_id=org
      and name='Receipt tracking verification — SIMULATED, NO SENDS' and status='completed') then
      raise exception 'Fixture identity collision'; end if;
    if (select count(*) from public.campaign_csv_recipients where campaign_id=campaign)=3 then return; end if;
    -- Recreate only our earlier synthetic fixture if its CSV snapshot was absent.
    -- Never edit immutable content of a started campaign or touch a real campaign.
    delete from public.campaigns where id=campaign;
  end if;
  select id,user_id into strict owner_agent,owner_user from public.agents where organization_id=org
    and user_id is not null and extra->>'role'='owner' order by id limit 1;
  insert into public.organizations_addresses(organization_id,address,service,status,extra)
    values(org,'141141000000001','whatsapp','disconnected','{"phone_number":"15550001411","verified_name":"Synthetic receipt fixture — no sends"}')
    on conflict(organization_id,address) do nothing;
  if not exists(select 1 from public.organizations_addresses where organization_id=org and address='141141000000001'
    and status='disconnected' and extra->>'verified_name'='Synthetic receipt fixture — no sends') then raise exception 'Fixture account collision'; end if;
  insert into public.campaigns(id,organization_id,created_by,name,organization_address,template,audience_type)
    values(campaign,org,owner_agent,'Receipt tracking verification — SIMULATED, NO SENDS','141141000000001',
      '{"id":"synthetic-no-send","name":"synthetic_no_send","language":"en_US","status":"APPROVED","components":[{"type":"BODY","text":"Synthetic staging receipt fixture. No message was sent."}]}','csv_upload');
  for n in 1..3 loop
    delivery:=('14114100-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    insert into public.campaign_deliveries(id,organization_id,campaign_id,contact_address)
      values(delivery,org,campaign,'1555000141'||n);
    insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address)
      values(org,campaign,'1555000141'||n);
  end loop;
  update public.campaigns set status='running',processing_count=3 where id=campaign;
  update public.campaign_deliveries set status='processing',attempts=1 where campaign_id=campaign;
  for n in 1..3 loop
    delivery:=('14114100-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    perform public.record_campaign_delivery_result(delivery,'wamid.fixture.campaign.141141.'||n);
    perform public.ingest_campaign_receipt(org,'141141000000001','wamid.fixture.campaign.141141.'||n,'sent',stamp);
    if n<=2 then
      perform public.ingest_campaign_receipt(org,'141141000000001','wamid.fixture.campaign.141141.'||n,'delivered',stamp+interval '1 second');
    else
      perform public.ingest_campaign_receipt(org,'141141000000001','wamid.fixture.campaign.141141.'||n,'failed',stamp+interval '1 second',null,'meta_131026');
    end if;
    if n=1 then perform public.ingest_campaign_receipt(org,'141141000000001','wamid.fixture.campaign.141141.1','read',stamp+interval '2 seconds'); end if;
  end loop;
  select count(*) into events_before from public.campaign_activity where campaign_id=campaign;
  perform public.ingest_campaign_receipt(org,'141141000000001','wamid.fixture.campaign.141141.1','read',stamp+interval '2 seconds');
  if events_before<>(select count(*) from public.campaign_activity where campaign_id=campaign) then raise exception 'Receipt duplicated'; end if;
  perform set_config('request.jwt.claim.sub',owner_user::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  result:=public.get_campaign_receipt_summary(org,campaign);
  if result<>'{"sent":3,"delivered":2,"read":1,"delivery_failed":1}'::jsonb then raise exception 'Receipt summary mismatch'; end if;
  if (select count(*) from public.list_campaign_activity_page(org,campaign,1,10))<>10
    or (select count(*) from public.list_campaign_activity_page(org,campaign,2,10))<1 then raise exception 'Pagination failed'; end if;
  if exists(select 1 from public.campaign_dispatch_jobs where campaign_id=campaign)
    or exists(select 1 from public.messages where organization_id=org and organization_address='141141000000001') then
    raise exception 'Fixture created sending work or chat messages'; end if;
  if (select status from public.campaigns where id=campaign)<>'completed' then raise exception 'Fixture not terminal'; end if;
end;
$$;
select 'staging_tracking_verification_passed' as result,id,name,status,accepted_count,failed_count,
  (select count(*) from public.campaign_activity where campaign_id=c.id) as activity_events
from public.campaigns c where c.id='14114100-0000-4000-8000-000000000099';
commit;
