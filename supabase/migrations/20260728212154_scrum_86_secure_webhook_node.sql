  create table "public"."chatbot_webhook_credentials" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "created_by" uuid,
    "name" text not null,
    "vault_secret_id" uuid not null,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."chatbot_webhook_credentials" enable row level security;

CREATE UNIQUE INDEX chatbot_webhook_credentials_organization_id_id_key ON public.chatbot_webhook_credentials USING btree (organization_id, id);

CREATE UNIQUE INDEX chatbot_webhook_credentials_organization_name_key ON public.chatbot_webhook_credentials USING btree (organization_id, lower(btrim(name)));

CREATE UNIQUE INDEX chatbot_webhook_credentials_pkey ON public.chatbot_webhook_credentials USING btree (id);

CREATE UNIQUE INDEX chatbot_webhook_credentials_vault_secret_id_key ON public.chatbot_webhook_credentials USING btree (vault_secret_id);

alter table "public"."chatbot_webhook_credentials" add constraint "chatbot_webhook_credentials_pkey" PRIMARY KEY using index "chatbot_webhook_credentials_pkey";

alter table "public"."chatbot_webhook_credentials" add constraint "chatbot_webhook_credentials_created_by_fkey" FOREIGN KEY (organization_id, created_by) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (created_by) not valid;

alter table "public"."chatbot_webhook_credentials" validate constraint "chatbot_webhook_credentials_created_by_fkey";

alter table "public"."chatbot_webhook_credentials" add constraint "chatbot_webhook_credentials_name_check" CHECK ((length(btrim(name)) > 0)) not valid;

alter table "public"."chatbot_webhook_credentials" validate constraint "chatbot_webhook_credentials_name_check";

alter table "public"."chatbot_webhook_credentials" add constraint "chatbot_webhook_credentials_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_webhook_credentials" validate constraint "chatbot_webhook_credentials_organization_id_fkey";

alter table "public"."chatbot_webhook_credentials" add constraint "chatbot_webhook_credentials_organization_id_id_key" UNIQUE using index "chatbot_webhook_credentials_organization_id_id_key";

alter table "public"."chatbot_webhook_credentials" add constraint "chatbot_webhook_credentials_vault_secret_id_key" UNIQUE using index "chatbot_webhook_credentials_vault_secret_id_key";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.create_chatbot_webhook_credential(p_organization_id uuid, p_name text, p_headers jsonb, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, name text, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  credential_id uuid := gen_random_uuid();
  vault_id uuid;
begin
  if jsonb_typeof(p_headers) <> 'object'
    or exists (
      select 1
      from jsonb_each(p_headers)
      where jsonb_typeof(value) <> 'string'
    )
  then
    raise exception using
      errcode = '22023',
      message = 'Credential headers must be a JSON object of string values';
  end if;

  vault_id := vault.create_secret(
    p_headers::text,
    'chatbot_webhook_' || credential_id::text,
    'Protected chatbot webhook headers'
  );

  return query
  insert into public.chatbot_webhook_credentials (
    organization_id,
    id,
    created_by,
    name,
    vault_secret_id
  )
  values (
    p_organization_id,
    credential_id,
    p_created_by,
    btrim(p_name),
    vault_id
  )
  returning
    chatbot_webhook_credentials.id,
    chatbot_webhook_credentials.name,
    chatbot_webhook_credentials.created_at,
    chatbot_webhook_credentials.updated_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_chatbot_webhook_vault_secret()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  delete from vault.secrets where id = old.vault_secret_id;
  return old;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_chatbot_webhook_credential(p_organization_id uuid, p_credential_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select decrypted_secret::jsonb
  from public.chatbot_webhook_credentials
  join vault.decrypted_secrets
    on decrypted_secrets.id = chatbot_webhook_credentials.vault_secret_id
  where chatbot_webhook_credentials.organization_id = p_organization_id
    and chatbot_webhook_credentials.id = p_credential_id;
$function$
;

grant select on table "public"."chatbot_webhook_credentials" to "anon";

grant select on table "public"."chatbot_webhook_credentials" to "authenticated";

grant delete on table "public"."chatbot_webhook_credentials" to "service_role";

grant select on table "public"."chatbot_webhook_credentials" to "service_role";


  create policy "admins can read their orgs chatbot webhook credentials"
  on "public"."chatbot_webhook_credentials"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));


CREATE TRIGGER delete_chatbot_webhook_vault_secret AFTER DELETE ON public.chatbot_webhook_credentials FOR EACH ROW EXECUTE FUNCTION public.delete_chatbot_webhook_vault_secret();

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.chatbot_webhook_credentials FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



revoke all
on function public.create_chatbot_webhook_credential(uuid, text, jsonb, uuid)
from public, anon, authenticated;

revoke all
on function public.resolve_chatbot_webhook_credential(uuid, uuid)
from public, anon, authenticated;

revoke all
on function public.delete_chatbot_webhook_vault_secret()
from public, anon, authenticated;

grant execute
on function public.create_chatbot_webhook_credential(uuid, text, jsonb, uuid)
to service_role;

grant execute
on function public.resolve_chatbot_webhook_credential(uuid, uuid)
to service_role;
