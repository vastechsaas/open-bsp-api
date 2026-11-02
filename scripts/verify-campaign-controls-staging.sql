-- Staging acifbsuxmpdtlhbsvhlj ONLY, after encrypted backup and migration.
-- Inert UI fixture: disconnected synthetic account, due in 2099, paused at commit.
-- Never invokes a sender/Edge Function, changes a real account or uses a customer.
begin;
do $$
declare org uuid; actor uuid; agent uuid; result jsonb; job uuid;
  campaign uuid:='15015000-0000-4000-8000-000000000099';
begin
  select id into strict org from public.organizations where name='SCRUM-128 PSDF isolated sync test';
  if exists(select 1 from public.campaigns where id=campaign) then
    if not exists(select 1 from public.campaigns where id=campaign and organization_id=org
      and name='Pause/resume verification — SIMULATED, NO SENDS' and paused_at is not null) then
      raise exception 'Fixture identity collision'; end if;
    return;
  end if;
  select a.id,a.user_id into strict agent,actor from public.agents a join auth.users u on u.id=a.user_id
    where a.organization_id=org and u.email='stagging@vistagalaxy.com' and a.extra->>'role'='owner';
  insert into public.organizations_addresses(organization_id,address,service,status,extra)
    values(org,'150150000000099','whatsapp','disconnected','{"phone_number":"15550001599","verified_name":"Pause fixture — disconnected, no sends"}')
    on conflict(organization_id,address) do nothing;
  if not exists(select 1 from public.organizations_addresses where organization_id=org and address='150150000000099'
    and status='disconnected' and extra->>'verified_name'='Pause fixture — disconnected, no sends') then
    raise exception 'Fixture address collision'; end if;
  insert into public.campaigns(id,organization_id,created_by,name,organization_address,template,audience_type,
    scheduled_start_at,schedule_timezone,send_window_start,send_window_end,dispatch_transport)
    values(campaign,org,agent,'Pause/resume verification — SIMULATED, NO SENDS','150150000000099',
      '{"id":"synthetic-no-send","name":"synthetic_no_send","language":"en_US","status":"APPROVED","components":[{"type":"BODY","text":"Synthetic pause/resume fixture. No message was sent."}]}',
      'csv_upload','2099-01-01T04:00:00Z','Asia/Karachi','09:00','18:00','cloudamqp');
  insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address) values(org,campaign,'15550001598');
  insert into public.campaign_deliveries(organization_id,campaign_id,contact_address) values(org,campaign,'15550001598');
  insert into public.campaign_dispatch_jobs(organization_id,campaign_id,delivery_id,due_at,publish_after,waiting_reason)
    select org,campaign,id,'2099-01-01T04:00:00Z','2099-01-01T04:00:00Z','scheduled'
    from public.campaign_deliveries where campaign_id=campaign returning id into job;
  update public.campaigns set status='queued',queued_count=1 where id=campaign;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
  result:=public.pause_campaign(org,campaign,0,'15015000-0000-4000-8000-000000000001');
  if result->>'control_revision'<>'1' or result->>'paused_at' is null then raise exception 'Pause failed'; end if;
  result:=public.claim_campaign_dispatch_job(job);
  if result->>'phase'<>'deferred' or result->>'reason'<>'manual_pause' then raise exception 'Paused job not deferred'; end if;
  result:=public.resume_campaign(org,campaign,1,'15015000-0000-4000-8000-000000000002');
  if result->>'control_revision'<>'2' or result->>'paused_at' is not null then raise exception 'Resume failed'; end if;
  result:=public.claim_campaign_dispatch_job(job);
  if result->>'phase'<>'deferred' or result->>'reason'<>'scheduled' then raise exception 'Resume bypassed schedule'; end if;
  result:=public.pause_campaign(org,campaign,0,'15015000-0000-4000-8000-000000000001');
  if result->>'paused_at' is not null then raise exception 'Old request replayed'; end if;
  perform public.pause_campaign(org,campaign,2,'15015000-0000-4000-8000-000000000003');
  if exists(select 1 from public.campaign_deliveries where campaign_id=campaign and attempts<>0)
    or exists(select 1 from public.campaign_send_ledger where delivery_id in(select id from public.campaign_deliveries where campaign_id=campaign)) then
    raise exception 'Fixture consumed a send'; end if;
end;
$$;
select 'staging_pause_resume_verified' as result,id,name,status,paused_at,control_revision,queued_count,accepted_count
  from public.campaigns where id='15015000-0000-4000-8000-000000000099';
commit;
