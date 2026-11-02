-- Manual hold is independent of delivery outcomes. Lock policy -> campaign -> job.
create function public.set_campaign_paused(p_organization_id uuid,p_campaign_id uuid,p_paused boolean,
  p_expected_revision bigint,p_request_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare c public.campaigns; previous public.campaign_activity; actor_name_value text; action text;
begin
  if public.get_request_organization_role(p_organization_id) is null or
    public.get_request_organization_role(p_organization_id) not in ('owner','admin','member') then
    raise exception 'Campaign management access required' using errcode='42501'; end if;
  if p_request_id is null or p_expected_revision is null or p_paused is null then
    raise exception 'Request ID, revision and action are required' using errcode='22023'; end if;
  perform public.lock_campaign_sending_policy(p_organization_id);
  select * into c from public.campaigns where organization_id=p_organization_id and id=p_campaign_id for update;
  if not found then raise exception 'Campaign not found' using errcode='P0002'; end if;
  action:=case when p_paused then 'campaign_paused' else 'campaign_resumed' end;
  select * into previous from public.campaign_activity
    where deduplication_key='campaign-control:'||c.id::text||':'||p_request_id::text;
  if found then
    if previous.event_type<>action or previous.actor_user_id is distinct from auth.uid() then
      raise exception 'Request ID was already used for another action' using errcode='22023'; end if;
    -- Reconcile current state, never reapply an old request after a later action.
    return jsonb_build_object('control_revision',c.control_revision,'paused_at',c.paused_at,
      'paused_by_name',c.paused_by_name,'request_revision',previous.control_revision);
  end if;
  if c.control_revision<>p_expected_revision then
    raise exception 'Campaign controls changed. Refresh before trying again.' using errcode='40001'; end if;
  if c.dispatch_transport<>'cloudamqp' or c.status not in ('queued','running','needs_review') or
    c.cancelled_at is not null or c.expires_at<=clock_timestamp() or c.queued_count+c.processing_count=0 then
    raise exception 'Only unfinished CloudAMQP campaigns can be paused or resumed' using errcode='23514'; end if;
  if (c.paused_at is not null)=p_paused then
    raise exception 'Campaign pause state already changed. Refresh before trying again.' using errcode='40001'; end if;
  select coalesce(nullif(btrim(a.name),''),'User') into actor_name_value from public.agents a
    where a.organization_id=p_organization_id and a.user_id=auth.uid() and not a.ai limit 1;
  actor_name_value:=coalesce(actor_name_value,'API key');
  update public.campaigns set paused_at=case when p_paused then clock_timestamp() else null end,
    paused_by_name=case when p_paused then actor_name_value else null end,control_revision=control_revision+1
    where id=c.id returning * into c;
  if not p_paused then
    -- Wake only provably unsent work; keep retry/schedule due_at intact.
    update public.campaign_dispatch_jobs set publication_token=null,publication_expires_at=null,
      publish_after=greatest(due_at,clock_timestamp()),
      waiting_reason=case when waiting_reason='manual_pause' then null else waiting_reason end,
      updated_at=clock_timestamp() where campaign_id=c.id and phase='pending';
  end if;
  insert into public.campaign_activity(organization_id,campaign_id,event_type,actor_user_id,actor_name,
    request_id,control_revision,deduplication_key)
    values(c.organization_id,c.id,action,auth.uid(),actor_name_value,p_request_id,c.control_revision,
      'campaign-control:'||c.id::text||':'||p_request_id::text);
  return jsonb_build_object('control_revision',c.control_revision,'paused_at',c.paused_at,
    'paused_by_name',c.paused_by_name,'request_revision',c.control_revision);
end;
$$;
revoke all on function public.set_campaign_paused(uuid,uuid,boolean,bigint,uuid) from public,anon,authenticated;
grant execute on function public.set_campaign_paused(uuid,uuid,boolean,bigint,uuid) to service_role;

create function public.pause_campaign(p_organization_id uuid,p_campaign_id uuid,p_expected_revision bigint,p_request_id uuid)
returns jsonb language sql volatile security definer set search_path='' as $$
  select public.set_campaign_paused(p_organization_id,p_campaign_id,true,p_expected_revision,p_request_id);
$$;
create function public.resume_campaign(p_organization_id uuid,p_campaign_id uuid,p_expected_revision bigint,p_request_id uuid)
returns jsonb language sql volatile security definer set search_path='' as $$
  select public.set_campaign_paused(p_organization_id,p_campaign_id,false,p_expected_revision,p_request_id);
$$;
revoke all on function public.pause_campaign(uuid,uuid,bigint,uuid),public.resume_campaign(uuid,uuid,bigint,uuid) from public;
grant execute on function public.pause_campaign(uuid,uuid,bigint,uuid),public.resume_campaign(uuid,uuid,bigint,uuid) to authenticated,anon,service_role;
