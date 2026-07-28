  create table "public"."chatbot_flow_deployments" (
    "organization_id" uuid not null,
    "organization_address" text not null,
    "flow_id" uuid not null,
    "flow_version_id" uuid not null,
    "agent_id" uuid not null,
    "activated_by" uuid,
    "activated_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."chatbot_flow_deployments" enable row level security;

CREATE INDEX chatbot_flow_deployments_flow_idx ON public.chatbot_flow_deployments USING btree (flow_id);

CREATE UNIQUE INDEX chatbot_flow_deployments_pkey ON public.chatbot_flow_deployments USING btree (organization_id, organization_address);

CREATE INDEX chatbot_flow_deployments_version_idx ON public.chatbot_flow_deployments USING btree (flow_version_id);

alter table "public"."chatbot_flow_deployments" add constraint "chatbot_flow_deployments_pkey" PRIMARY KEY using index "chatbot_flow_deployments_pkey";

alter table "public"."chatbot_flow_deployments" add constraint "chatbot_flow_deployments_activated_by_fkey" FOREIGN KEY (organization_id, activated_by) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (activated_by) not valid;

alter table "public"."chatbot_flow_deployments" validate constraint "chatbot_flow_deployments_activated_by_fkey";

alter table "public"."chatbot_flow_deployments" add constraint "chatbot_flow_deployments_address_fkey" FOREIGN KEY (organization_id, organization_address) REFERENCES public.organizations_addresses(organization_id, address) ON DELETE CASCADE not valid;

alter table "public"."chatbot_flow_deployments" validate constraint "chatbot_flow_deployments_address_fkey";

alter table "public"."chatbot_flow_deployments" add constraint "chatbot_flow_deployments_agent_fkey" FOREIGN KEY (organization_id, agent_id) REFERENCES public.agents(organization_id, id) ON DELETE RESTRICT not valid;

alter table "public"."chatbot_flow_deployments" validate constraint "chatbot_flow_deployments_agent_fkey";

alter table "public"."chatbot_flow_deployments" add constraint "chatbot_flow_deployments_flow_fkey" FOREIGN KEY (organization_id, flow_id) REFERENCES public.chatbot_flows(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_flow_deployments" validate constraint "chatbot_flow_deployments_flow_fkey";

alter table "public"."chatbot_flow_deployments" add constraint "chatbot_flow_deployments_version_fkey" FOREIGN KEY (organization_id, flow_version_id) REFERENCES public.chatbot_flow_versions(organization_id, id) ON DELETE RESTRICT not valid;

alter table "public"."chatbot_flow_deployments" validate constraint "chatbot_flow_deployments_version_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.validate_chatbot_flow_deployment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  target_version public.chatbot_flow_versions;
  target_agent public.agents;
begin
  if not exists (
    select 1
    from public.organizations_addresses as address
    where address.organization_id = new.organization_id
      and address.address = new.organization_address
      and address.service = 'whatsapp'::public.service
      and address.status = 'connected'
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require a connected WhatsApp address';
  end if;

  if not exists (
    select 1
    from public.chatbot_flows as flow
    where flow.organization_id = new.organization_id
      and flow.id = new.flow_id
      and flow.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require an active flow from the same organization';
  end if;

  select * into target_version
  from public.chatbot_flow_versions as version
  where version.organization_id = new.organization_id
    and version.id = new.flow_version_id;

  if not found
    or target_version.flow_id <> new.flow_id
    or target_version.status <> 'published'
  then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require a published version of the selected flow';
  end if;

  select * into target_agent
  from public.agents as agent
  where agent.organization_id = new.organization_id
    and agent.id = new.agent_id;

  if not found
    or target_agent.ai is distinct from true
    or target_agent.extra->>'mode' = 'inactive'
  then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require an active AI agent from the same organization';
  end if;

  if new.activated_by is not null and not exists (
    select 1
    from public.agents as actor
    where actor.organization_id = new.organization_id
      and actor.id = new.activated_by
      and actor.ai = false
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployment actor must be a human agent from the same organization';
  end if;

  return new;
end;
$function$
;

grant delete on table "public"."chatbot_flow_deployments" to "anon";

grant insert on table "public"."chatbot_flow_deployments" to "anon";

grant references on table "public"."chatbot_flow_deployments" to "anon";

grant select on table "public"."chatbot_flow_deployments" to "anon";

grant trigger on table "public"."chatbot_flow_deployments" to "anon";

grant truncate on table "public"."chatbot_flow_deployments" to "anon";

grant update on table "public"."chatbot_flow_deployments" to "anon";

grant delete on table "public"."chatbot_flow_deployments" to "authenticated";

grant insert on table "public"."chatbot_flow_deployments" to "authenticated";

grant references on table "public"."chatbot_flow_deployments" to "authenticated";

grant select on table "public"."chatbot_flow_deployments" to "authenticated";

grant trigger on table "public"."chatbot_flow_deployments" to "authenticated";

grant truncate on table "public"."chatbot_flow_deployments" to "authenticated";

grant update on table "public"."chatbot_flow_deployments" to "authenticated";

grant delete on table "public"."chatbot_flow_deployments" to "service_role";

grant insert on table "public"."chatbot_flow_deployments" to "service_role";

grant references on table "public"."chatbot_flow_deployments" to "service_role";

grant select on table "public"."chatbot_flow_deployments" to "service_role";

grant trigger on table "public"."chatbot_flow_deployments" to "service_role";

grant truncate on table "public"."chatbot_flow_deployments" to "service_role";

grant update on table "public"."chatbot_flow_deployments" to "service_role";


  create policy "admins can create their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for insert
  to authenticated, anon
with check ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "admins can delete their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for delete
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "admins can update their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for update
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "members can read their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.chatbot_flow_deployments FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE TRIGGER validate_chatbot_flow_deployment BEFORE INSERT OR UPDATE ON public.chatbot_flow_deployments FOR EACH ROW EXECUTE FUNCTION public.validate_chatbot_flow_deployment();
