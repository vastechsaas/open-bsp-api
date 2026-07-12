alter table "public"."conversations" add column "assigned_agent_id" uuid;

CREATE UNIQUE INDEX agents_organization_id_id_key ON public.agents USING btree (organization_id, id);

CREATE INDEX conversations_organization_id_assigned_agent_id_idx ON public.conversations USING btree (organization_id, assigned_agent_id);

alter table "public"."agents" add constraint "agents_organization_id_id_key" UNIQUE using index "agents_organization_id_id_key";

alter table "public"."conversations" add constraint "conversations_organization_id_assigned_agent_id_fkey" FOREIGN KEY (organization_id, assigned_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (assigned_agent_id) not valid;

alter table "public"."conversations" validate constraint "conversations_organization_id_assigned_agent_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.enforce_human_conversation_assignee()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.assigned_agent_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.agents
    where id = new.assigned_agent_id
      and organization_id = new.organization_id
      and ai = false
      and user_id is not null
  ) then
    raise exception 'Conversation assignee must be a human agent in the same organization'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE TRIGGER enforce_human_conversation_assignee BEFORE INSERT OR UPDATE OF assigned_agent_id, organization_id ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.enforce_human_conversation_assignee();


