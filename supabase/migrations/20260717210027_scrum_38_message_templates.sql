  create table "public"."message_templates" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "organization_address" text not null,
    "created_by" uuid,
    "external_id" text,
    "name" text not null,
    "language" text not null,
    "category" text not null,
    "status" text not null default 'draft'::text,
    "components" jsonb not null default '[]'::jsonb,
    "rejection_reason" text,
    "submitted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."message_templates" enable row level security;

CREATE UNIQUE INDEX message_templates_account_name_language_key ON public.message_templates USING btree (organization_id, organization_address, name, language);

CREATE INDEX message_templates_organization_account_idx ON public.message_templates USING btree (organization_id, organization_address);

CREATE INDEX message_templates_organization_category_status_idx ON public.message_templates USING btree (organization_id, category, status);

CREATE UNIQUE INDEX message_templates_organization_external_id_key ON public.message_templates USING btree (organization_id, external_id);

CREATE UNIQUE INDEX message_templates_organization_id_id_key ON public.message_templates USING btree (organization_id, id);

CREATE INDEX message_templates_organization_updated_at_idx ON public.message_templates USING btree (organization_id, updated_at DESC, id DESC);

CREATE UNIQUE INDEX message_templates_pkey ON public.message_templates USING btree (id);

alter table "public"."message_templates" add constraint "message_templates_pkey" PRIMARY KEY using index "message_templates_pkey";

alter table "public"."message_templates" add constraint "message_templates_account_name_language_key" UNIQUE using index "message_templates_account_name_language_key";

alter table "public"."message_templates" add constraint "message_templates_category_check" CHECK ((category = ANY (ARRAY['utility'::text, 'marketing'::text, 'authentication'::text]))) not valid;

alter table "public"."message_templates" validate constraint "message_templates_category_check";

alter table "public"."message_templates" add constraint "message_templates_components_check" CHECK ((jsonb_typeof(components) = 'array'::text)) not valid;

alter table "public"."message_templates" validate constraint "message_templates_components_check";

alter table "public"."message_templates" add constraint "message_templates_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.agents(id) ON DELETE SET NULL not valid;

alter table "public"."message_templates" validate constraint "message_templates_created_by_fkey";

alter table "public"."message_templates" add constraint "message_templates_external_state_check" CHECK ((((status = 'draft'::text) AND (external_id IS NULL)) OR ((status <> 'draft'::text) AND (external_id IS NOT NULL)))) not valid;

alter table "public"."message_templates" validate constraint "message_templates_external_state_check";

alter table "public"."message_templates" add constraint "message_templates_language_check" CHECK ((length(btrim(language)) > 0)) not valid;

alter table "public"."message_templates" validate constraint "message_templates_language_check";

alter table "public"."message_templates" add constraint "message_templates_name_check" CHECK ((length(btrim(name)) > 0)) not valid;

alter table "public"."message_templates" validate constraint "message_templates_name_check";

alter table "public"."message_templates" add constraint "message_templates_organization_address_fkey" FOREIGN KEY (organization_id, organization_address) REFERENCES public.organizations_addresses(organization_id, address) ON DELETE CASCADE not valid;

alter table "public"."message_templates" validate constraint "message_templates_organization_address_fkey";

alter table "public"."message_templates" add constraint "message_templates_organization_external_id_key" UNIQUE using index "message_templates_organization_external_id_key";

alter table "public"."message_templates" add constraint "message_templates_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."message_templates" validate constraint "message_templates_organization_id_fkey";

alter table "public"."message_templates" add constraint "message_templates_organization_id_id_key" UNIQUE using index "message_templates_organization_id_id_key";

alter table "public"."message_templates" add constraint "message_templates_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'pending'::text, 'approved'::text, 'in_appeal'::text, 'rejected'::text, 'pending_deletion'::text, 'deleted'::text, 'disabled'::text, 'paused'::text, 'limit_exceeded'::text]))) not valid;

alter table "public"."message_templates" validate constraint "message_templates_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.enforce_message_template_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if not exists (
    select 1
    from public.organizations_addresses
    where organization_id = new.organization_id
      and address = new.organization_address
      and service = 'whatsapp'::public.service
  ) then
    raise exception 'Template account must be a WhatsApp address in the same organization'
      using errcode = '23514';
  end if;

  if new.created_by is not null and not exists (
    select 1
    from public.agents
    where id = new.created_by
      and organization_id = new.organization_id
  ) then
    raise exception 'Template creator must belong to the template organization'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_message_templates_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_organization_address text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, organization_address text, created_by uuid, external_id text, name text, language text, category text, status text, components jsonb, rejection_reason text, submitted_at timestamp with time zone, synced_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_account text;
  normalized_category text;
  normalized_status text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 100);
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_account := nullif(btrim(coalesce(p_organization_address, '')), '');
  normalized_category := nullif(lower(btrim(coalesce(p_category, ''))), '');
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_category is not null
    and normalized_category not in ('utility', 'marketing', 'authentication')
  then
    raise exception using
      errcode = '22023',
      message = 'template category filter is invalid';
  end if;

  if normalized_status is not null
    and normalized_status not in (
      'draft',
      'pending',
      'approved',
      'in_appeal',
      'rejected',
      'pending_deletion',
      'deleted',
      'disabled',
      'paused',
      'limit_exceeded'
    )
  then
    raise exception using
      errcode = '22023',
      message = 'template status filter is invalid';
  end if;

  return query
  select
    template.organization_id,
    template.id,
    template.organization_address,
    template.created_by,
    template.external_id,
    template.name,
    template.language,
    template.category,
    template.status,
    template.components,
    template.rejection_reason,
    template.submitted_at,
    template.synced_at,
    template.created_at,
    template.updated_at,
    count(*) over() as total_count
  from public.message_templates template
  where template.organization_id = p_organization_id
    and (
      normalized_account is null
      or template.organization_address = normalized_account
    )
    and (
      normalized_category is null
      or template.category = normalized_category
    )
    and (
      normalized_status is null
      or template.status = normalized_status
    )
    and (
      normalized_search = ''
      or position(normalized_search in lower(template.name)) > 0
      or position(
        normalized_search in lower(template.organization_address)
      ) > 0
    )
  order by template.updated_at desc, template.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

grant references on table "public"."message_templates" to "anon";

grant trigger on table "public"."message_templates" to "anon";

grant truncate on table "public"."message_templates" to "anon";

grant delete on table "public"."message_templates" to "anon";

grant insert on table "public"."message_templates" to "anon";

grant select on table "public"."message_templates" to "anon";

grant update on table "public"."message_templates" to "anon";

grant references on table "public"."message_templates" to "authenticated";

grant trigger on table "public"."message_templates" to "authenticated";

grant truncate on table "public"."message_templates" to "authenticated";

grant delete on table "public"."message_templates" to "authenticated";

grant insert on table "public"."message_templates" to "authenticated";

grant select on table "public"."message_templates" to "authenticated";

grant update on table "public"."message_templates" to "authenticated";

grant references on table "public"."message_templates" to "service_role";

grant trigger on table "public"."message_templates" to "service_role";

grant truncate on table "public"."message_templates" to "service_role";

grant delete on table "public"."message_templates" to "service_role";

grant insert on table "public"."message_templates" to "service_role";

grant select on table "public"."message_templates" to "service_role";

grant update on table "public"."message_templates" to "service_role";


  create policy "admins can create their orgs message templates"
  on "public"."message_templates"
  as permissive
  for insert
  to authenticated, anon
with check ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "admins can delete their orgs message templates"
  on "public"."message_templates"
  as permissive
  for delete
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "admins can update their orgs message templates"
  on "public"."message_templates"
  as permissive
  for update
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)));



  create policy "members can read their orgs message templates"
  on "public"."message_templates"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));


CREATE TRIGGER enforce_message_template_rules BEFORE INSERT OR UPDATE OF organization_id, organization_address, created_by ON public.message_templates FOR EACH ROW EXECUTE FUNCTION public.enforce_message_template_rules();

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.message_templates FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');
