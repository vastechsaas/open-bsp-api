  create table "public"."chatbot_flow_runs" (
    "organization_id" uuid not null,
    "conversation_id" uuid not null,
    "flow_version_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "current_node_id" text,
    "status" text not null default 'running'::text,
    "waiting_for" text,
    "variables" jsonb not null default '{}'::jsonb,
    "last_processed_message_id" uuid,
    "error" jsonb,
    "started_at" timestamp with time zone not null default now(),
    "expires_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."chatbot_flow_runs" enable row level security;


  create table "public"."chatbot_flow_versions" (
    "organization_id" uuid not null,
    "flow_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "created_by" uuid,
    "version" integer not null,
    "status" text not null default 'draft'::text,
    "editor_graph" jsonb not null default '{"edges": [], "nodes": []}'::jsonb,
    "definition" jsonb,
    "published_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."chatbot_flow_versions" enable row level security;


  create table "public"."chatbot_flows" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "created_by" uuid,
    "name" text not null,
    "status" text not null default 'active'::text,
    "archived_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."chatbot_flows" enable row level security;

CREATE INDEX chatbot_flow_runs_expires_at_idx ON public.chatbot_flow_runs USING btree (expires_at) WHERE ((status = ANY (ARRAY['running'::text, 'waiting'::text])) AND (expires_at IS NOT NULL));

CREATE INDEX chatbot_flow_runs_flow_version_idx ON public.chatbot_flow_runs USING btree (flow_version_id);

CREATE UNIQUE INDEX chatbot_flow_runs_one_active_per_conversation_idx ON public.chatbot_flow_runs USING btree (conversation_id) WHERE (status = ANY (ARRAY['running'::text, 'waiting'::text]));

CREATE UNIQUE INDEX chatbot_flow_runs_organization_id_id_key ON public.chatbot_flow_runs USING btree (organization_id, id);

CREATE INDEX chatbot_flow_runs_organization_status_updated_at_idx ON public.chatbot_flow_runs USING btree (organization_id, status, updated_at DESC);

CREATE UNIQUE INDEX chatbot_flow_runs_pkey ON public.chatbot_flow_runs USING btree (id);

CREATE INDEX chatbot_flow_versions_flow_status_version_idx ON public.chatbot_flow_versions USING btree (flow_id, status, version DESC);

CREATE UNIQUE INDEX chatbot_flow_versions_flow_version_key ON public.chatbot_flow_versions USING btree (flow_id, version);

CREATE UNIQUE INDEX chatbot_flow_versions_one_draft_per_flow_idx ON public.chatbot_flow_versions USING btree (flow_id) WHERE (status = 'draft'::text);

CREATE UNIQUE INDEX chatbot_flow_versions_organization_id_id_key ON public.chatbot_flow_versions USING btree (organization_id, id);

CREATE UNIQUE INDEX chatbot_flow_versions_pkey ON public.chatbot_flow_versions USING btree (id);

CREATE UNIQUE INDEX chatbot_flows_organization_id_id_key ON public.chatbot_flows USING btree (organization_id, id);

CREATE UNIQUE INDEX chatbot_flows_organization_name_key ON public.chatbot_flows USING btree (organization_id, lower(btrim(name)));

CREATE INDEX chatbot_flows_organization_updated_at_idx ON public.chatbot_flows USING btree (organization_id, updated_at DESC, id DESC);

CREATE UNIQUE INDEX chatbot_flows_pkey ON public.chatbot_flows USING btree (id);

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_pkey" PRIMARY KEY using index "chatbot_flow_runs_pkey";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_pkey" PRIMARY KEY using index "chatbot_flow_versions_pkey";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_pkey" PRIMARY KEY using index "chatbot_flows_pkey";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_conversation_fkey" FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_conversation_fkey";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_current_node_check" CHECK (((status <> ALL (ARRAY['running'::text, 'waiting'::text])) OR ((current_node_id IS NOT NULL) AND (length(btrim(current_node_id)) > 0)))) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_current_node_check";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_ended_at_check" CHECK ((((status = ANY (ARRAY['running'::text, 'waiting'::text])) AND (ended_at IS NULL)) OR ((status = ANY (ARRAY['completed'::text, 'failed'::text, 'handed_off'::text, 'expired'::text])) AND (ended_at IS NOT NULL)))) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_ended_at_check";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_error_check" CHECK (((error IS NULL) OR (jsonb_typeof(error) = 'object'::text))) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_error_check";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_expiry_check" CHECK (((expires_at IS NULL) OR (expires_at > started_at))) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_expiry_check";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_flow_version_fkey" FOREIGN KEY (organization_id, flow_version_id) REFERENCES chatbot_flow_versions(organization_id, id) ON DELETE RESTRICT not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_flow_version_fkey";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_last_processed_message_fkey" FOREIGN KEY (last_processed_message_id) REFERENCES messages(id) ON DELETE SET NULL not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_last_processed_message_fkey";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_organization_id_fkey";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_organization_id_id_key" UNIQUE using index "chatbot_flow_runs_organization_id_id_key";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_status_check" CHECK ((status = ANY (ARRAY['running'::text, 'waiting'::text, 'completed'::text, 'failed'::text, 'handed_off'::text, 'expired'::text]))) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_status_check";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_variables_check" CHECK ((jsonb_typeof(variables) = 'object'::text)) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_variables_check";

alter table "public"."chatbot_flow_runs" add constraint "chatbot_flow_runs_waiting_for_check" CHECK ((((status = 'waiting'::text) AND (waiting_for IS NOT NULL) AND (waiting_for = ANY (ARRAY['free_text'::text, 'button'::text, 'list_selection'::text]))) OR ((status <> 'waiting'::text) AND (waiting_for IS NULL)))) not valid;

alter table "public"."chatbot_flow_runs" validate constraint "chatbot_flow_runs_waiting_for_check";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_created_by_fkey" FOREIGN KEY (organization_id, created_by) REFERENCES agents(organization_id, id) ON DELETE SET NULL (created_by) not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_created_by_fkey";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_definition_check" CHECK (((definition IS NULL) OR ((jsonb_typeof(definition) = 'object'::text) AND (definition ? 'schema_version'::text) AND (definition ? 'start_node_id'::text) AND (definition ? 'nodes'::text) AND (definition ? 'edges'::text) AND (jsonb_typeof((definition -> 'schema_version'::text)) = 'number'::text) AND (((definition ->> 'schema_version'::text))::numeric >= (1)::numeric) AND (trunc(((definition ->> 'schema_version'::text))::numeric) = ((definition ->> 'schema_version'::text))::numeric) AND (jsonb_typeof((definition -> 'start_node_id'::text)) = 'string'::text) AND (length(btrim((definition ->> 'start_node_id'::text))) > 0) AND (jsonb_typeof((definition -> 'nodes'::text)) = 'array'::text) AND (jsonb_typeof((definition -> 'edges'::text)) = 'array'::text)))) not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_definition_check";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_editor_graph_check" CHECK (((jsonb_typeof(editor_graph) = 'object'::text) AND (editor_graph ? 'nodes'::text) AND (editor_graph ? 'edges'::text) AND (jsonb_typeof((editor_graph -> 'nodes'::text)) = 'array'::text) AND (jsonb_typeof((editor_graph -> 'edges'::text)) = 'array'::text))) not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_editor_graph_check";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_flow_fkey" FOREIGN KEY (organization_id, flow_id) REFERENCES chatbot_flows(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_flow_fkey";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_flow_version_key" UNIQUE using index "chatbot_flow_versions_flow_version_key";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_organization_id_id_key" UNIQUE using index "chatbot_flow_versions_organization_id_id_key";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_published_state_check" CHECK ((((status = 'draft'::text) AND (published_at IS NULL)) OR ((status = 'published'::text) AND (published_at IS NOT NULL) AND (definition IS NOT NULL)))) not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_published_state_check";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text]))) not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_status_check";

alter table "public"."chatbot_flow_versions" add constraint "chatbot_flow_versions_version_check" CHECK ((version > 0)) not valid;

alter table "public"."chatbot_flow_versions" validate constraint "chatbot_flow_versions_version_check";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_archived_at_check" CHECK ((((status = 'active'::text) AND (archived_at IS NULL)) OR ((status = 'archived'::text) AND (archived_at IS NOT NULL)))) not valid;

alter table "public"."chatbot_flows" validate constraint "chatbot_flows_archived_at_check";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_created_by_fkey" FOREIGN KEY (organization_id, created_by) REFERENCES agents(organization_id, id) ON DELETE SET NULL (created_by) not valid;

alter table "public"."chatbot_flows" validate constraint "chatbot_flows_created_by_fkey";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_name_check" CHECK ((length(btrim(name)) > 0)) not valid;

alter table "public"."chatbot_flows" validate constraint "chatbot_flows_name_check";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_flows" validate constraint "chatbot_flows_organization_id_fkey";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_organization_id_id_key" UNIQUE using index "chatbot_flows_organization_id_id_key";

alter table "public"."chatbot_flows" add constraint "chatbot_flows_status_check" CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text]))) not valid;

alter table "public"."chatbot_flows" validate constraint "chatbot_flows_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.protect_published_chatbot_flow_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if old.status = 'published' then
    raise exception using
      errcode = '23514',
      message = 'published chatbot flow versions are immutable';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.validate_chatbot_flow_run()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  version_status text;
  conversation_organization_id uuid;
  message_conversation_id uuid;
begin
  if tg_op = 'UPDATE' and (
    new.organization_id <> old.organization_id
    or new.conversation_id <> old.conversation_id
    or new.flow_version_id <> old.flow_version_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow run identity is immutable';
  end if;

  select version.status
  into version_status
  from public.chatbot_flow_versions as version
  where version.organization_id = new.organization_id
    and version.id = new.flow_version_id;

  if version_status is distinct from 'published' then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow runs require a published flow version';
  end if;

  select conversation.organization_id
  into conversation_organization_id
  from public.conversations as conversation
  where conversation.id = new.conversation_id;

  if conversation_organization_id is distinct from new.organization_id then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow run conversation must belong to the same organization';
  end if;

  if new.last_processed_message_id is not null then
    select message.conversation_id
    into message_conversation_id
    from public.messages as message
    where message.id = new.last_processed_message_id;

    if message_conversation_id is distinct from new.conversation_id then
      raise exception using
        errcode = '23514',
        message = 'last processed message must belong to the chatbot flow run conversation';
    end if;
  end if;

  return new;
end;
$function$
;

grant delete on table "public"."chatbot_flow_runs" to "anon";

grant insert on table "public"."chatbot_flow_runs" to "anon";

grant references on table "public"."chatbot_flow_runs" to "anon";

grant select on table "public"."chatbot_flow_runs" to "anon";

grant trigger on table "public"."chatbot_flow_runs" to "anon";

grant truncate on table "public"."chatbot_flow_runs" to "anon";

grant update on table "public"."chatbot_flow_runs" to "anon";

grant delete on table "public"."chatbot_flow_runs" to "authenticated";

grant insert on table "public"."chatbot_flow_runs" to "authenticated";

grant references on table "public"."chatbot_flow_runs" to "authenticated";

grant select on table "public"."chatbot_flow_runs" to "authenticated";

grant trigger on table "public"."chatbot_flow_runs" to "authenticated";

grant truncate on table "public"."chatbot_flow_runs" to "authenticated";

grant update on table "public"."chatbot_flow_runs" to "authenticated";

grant delete on table "public"."chatbot_flow_runs" to "service_role";

grant insert on table "public"."chatbot_flow_runs" to "service_role";

grant references on table "public"."chatbot_flow_runs" to "service_role";

grant select on table "public"."chatbot_flow_runs" to "service_role";

grant trigger on table "public"."chatbot_flow_runs" to "service_role";

grant truncate on table "public"."chatbot_flow_runs" to "service_role";

grant update on table "public"."chatbot_flow_runs" to "service_role";

grant delete on table "public"."chatbot_flow_versions" to "anon";

grant insert on table "public"."chatbot_flow_versions" to "anon";

grant references on table "public"."chatbot_flow_versions" to "anon";

grant select on table "public"."chatbot_flow_versions" to "anon";

grant trigger on table "public"."chatbot_flow_versions" to "anon";

grant truncate on table "public"."chatbot_flow_versions" to "anon";

grant update on table "public"."chatbot_flow_versions" to "anon";

grant delete on table "public"."chatbot_flow_versions" to "authenticated";

grant insert on table "public"."chatbot_flow_versions" to "authenticated";

grant references on table "public"."chatbot_flow_versions" to "authenticated";

grant select on table "public"."chatbot_flow_versions" to "authenticated";

grant trigger on table "public"."chatbot_flow_versions" to "authenticated";

grant truncate on table "public"."chatbot_flow_versions" to "authenticated";

grant update on table "public"."chatbot_flow_versions" to "authenticated";

grant delete on table "public"."chatbot_flow_versions" to "service_role";

grant insert on table "public"."chatbot_flow_versions" to "service_role";

grant references on table "public"."chatbot_flow_versions" to "service_role";

grant select on table "public"."chatbot_flow_versions" to "service_role";

grant trigger on table "public"."chatbot_flow_versions" to "service_role";

grant truncate on table "public"."chatbot_flow_versions" to "service_role";

grant update on table "public"."chatbot_flow_versions" to "service_role";

grant delete on table "public"."chatbot_flows" to "anon";

grant insert on table "public"."chatbot_flows" to "anon";

grant references on table "public"."chatbot_flows" to "anon";

grant select on table "public"."chatbot_flows" to "anon";

grant trigger on table "public"."chatbot_flows" to "anon";

grant truncate on table "public"."chatbot_flows" to "anon";

grant update on table "public"."chatbot_flows" to "anon";

grant delete on table "public"."chatbot_flows" to "authenticated";

grant insert on table "public"."chatbot_flows" to "authenticated";

grant references on table "public"."chatbot_flows" to "authenticated";

grant select on table "public"."chatbot_flows" to "authenticated";

grant trigger on table "public"."chatbot_flows" to "authenticated";

grant truncate on table "public"."chatbot_flows" to "authenticated";

grant update on table "public"."chatbot_flows" to "authenticated";

grant delete on table "public"."chatbot_flows" to "service_role";

grant insert on table "public"."chatbot_flows" to "service_role";

grant references on table "public"."chatbot_flows" to "service_role";

grant select on table "public"."chatbot_flows" to "service_role";

grant trigger on table "public"."chatbot_flows" to "service_role";

grant truncate on table "public"."chatbot_flows" to "service_role";

grant update on table "public"."chatbot_flows" to "service_role";


  create policy "members can read their orgs chatbot flow runs"
  on "public"."chatbot_flow_runs"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT get_authorized_orgs('member'::role) AS get_authorized_orgs)));



  create policy "admins can create chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)) AND (status = 'draft'::text)));



  create policy "admins can delete chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)) AND (status = 'draft'::text)));



  create policy "admins can update chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)) AND (status = 'draft'::text)))
with check ((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)));



  create policy "members can read their orgs chatbot flow versions"
  on "public"."chatbot_flow_versions"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT get_authorized_orgs('member'::role) AS get_authorized_orgs)));



  create policy "admins can create their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for insert
  to authenticated, anon
with check ((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)));



  create policy "admins can delete their orgs unpublished chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)) AND (NOT (EXISTS ( SELECT 1
   FROM chatbot_flow_versions version
  WHERE ((version.flow_id = chatbot_flows.id) AND (version.status = 'published'::text)))))));



  create policy "admins can update their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for update
  to authenticated, anon
using ((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT get_authorized_orgs('admin'::role) AS get_authorized_orgs)));



  create policy "members can read their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT get_authorized_orgs('member'::role) AS get_authorized_orgs)));


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.chatbot_flow_runs FOR EACH ROW EXECUTE FUNCTION moddatetime('updated_at');

CREATE TRIGGER validate_chatbot_flow_run BEFORE INSERT OR UPDATE ON public.chatbot_flow_runs FOR EACH ROW EXECUTE FUNCTION validate_chatbot_flow_run();

CREATE TRIGGER protect_published_chatbot_flow_version BEFORE UPDATE ON public.chatbot_flow_versions FOR EACH ROW EXECUTE FUNCTION protect_published_chatbot_flow_version();

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.chatbot_flow_versions FOR EACH ROW EXECUTE FUNCTION moddatetime('updated_at');

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.chatbot_flows FOR EACH ROW EXECUTE FUNCTION moddatetime('updated_at');
