create type "public"."campaign_audience_type" as enum ('all_contacts', 'active_24h', 'csv_upload');


  create table "public"."campaign_csv_recipients" (
    "organization_id" uuid not null,
    "campaign_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "contact_address" text not null,
    "name" text,
    "variables" jsonb not null default '{}'::jsonb,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."campaign_csv_recipients" enable row level security;


  create table "public"."campaigns" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "created_by" uuid,
    "name" text not null,
    "service" public.service not null default 'whatsapp'::public.service,
    "organization_address" text not null,
    "template" jsonb not null,
    "template_variable_mapping" jsonb not null default '{}'::jsonb,
    "audience_type" public.campaign_audience_type not null,
    "status" text not null default 'draft'::text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."campaigns" enable row level security;

CREATE UNIQUE INDEX campaign_csv_recipients_campaign_address_key ON public.campaign_csv_recipients USING btree (campaign_id, contact_address);

CREATE INDEX campaign_csv_recipients_campaign_id_idx ON public.campaign_csv_recipients USING btree (campaign_id);

CREATE INDEX campaign_csv_recipients_organization_id_idx ON public.campaign_csv_recipients USING btree (organization_id);

CREATE UNIQUE INDEX campaign_csv_recipients_pkey ON public.campaign_csv_recipients USING btree (id);

CREATE UNIQUE INDEX campaigns_organization_id_id_key ON public.campaigns USING btree (organization_id, id);

CREATE INDEX campaigns_organization_id_idx ON public.campaigns USING btree (organization_id);

CREATE INDEX campaigns_organization_updated_at_idx ON public.campaigns USING btree (organization_id, updated_at DESC);

CREATE UNIQUE INDEX campaigns_pkey ON public.campaigns USING btree (id);

alter table "public"."campaign_csv_recipients" add constraint "campaign_csv_recipients_pkey" PRIMARY KEY using index "campaign_csv_recipients_pkey";

alter table "public"."campaigns" add constraint "campaigns_pkey" PRIMARY KEY using index "campaigns_pkey";

alter table "public"."campaign_csv_recipients" add constraint "campaign_csv_recipients_campaign_address_key" UNIQUE using index "campaign_csv_recipients_campaign_address_key";

alter table "public"."campaign_csv_recipients" add constraint "campaign_csv_recipients_campaign_fkey" FOREIGN KEY (organization_id, campaign_id) REFERENCES public.campaigns(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_csv_recipients" validate constraint "campaign_csv_recipients_campaign_fkey";

alter table "public"."campaign_csv_recipients" add constraint "campaign_csv_recipients_contact_address_check" CHECK ((length(btrim(contact_address)) > 0)) not valid;

alter table "public"."campaign_csv_recipients" validate constraint "campaign_csv_recipients_contact_address_check";

alter table "public"."campaign_csv_recipients" add constraint "campaign_csv_recipients_variables_check" CHECK ((jsonb_typeof(variables) = 'object'::text)) not valid;

alter table "public"."campaign_csv_recipients" validate constraint "campaign_csv_recipients_variables_check";

alter table "public"."campaigns" add constraint "campaigns_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.agents(id) ON DELETE SET NULL not valid;

alter table "public"."campaigns" validate constraint "campaigns_created_by_fkey";

alter table "public"."campaigns" add constraint "campaigns_name_check" CHECK ((length(btrim(name)) > 0)) not valid;

alter table "public"."campaigns" validate constraint "campaigns_name_check";

alter table "public"."campaigns" add constraint "campaigns_organization_address_fkey" FOREIGN KEY (organization_id, organization_address) REFERENCES public.organizations_addresses(organization_id, address) not valid;

alter table "public"."campaigns" validate constraint "campaigns_organization_address_fkey";

alter table "public"."campaigns" add constraint "campaigns_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."campaigns" validate constraint "campaigns_organization_id_fkey";

alter table "public"."campaigns" add constraint "campaigns_organization_id_id_key" UNIQUE using index "campaigns_organization_id_id_key";

alter table "public"."campaigns" add constraint "campaigns_service_check" CHECK ((service = 'whatsapp'::public.service)) not valid;

alter table "public"."campaigns" validate constraint "campaigns_service_check";

alter table "public"."campaigns" add constraint "campaigns_status_check" CHECK ((status = 'draft'::text)) not valid;

alter table "public"."campaigns" validate constraint "campaigns_status_check";

alter table "public"."campaigns" add constraint "campaigns_template_check" CHECK (((jsonb_typeof(template) = 'object'::text) AND (length(COALESCE((template ->> 'id'::text), ''::text)) > 0) AND (length(COALESCE((template ->> 'name'::text), ''::text)) > 0) AND (length(COALESCE((template ->> 'language'::text), ''::text)) > 0) AND ((template ->> 'status'::text) = 'APPROVED'::text))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_template_check";

alter table "public"."campaigns" add constraint "campaigns_template_variable_mapping_check" CHECK ((jsonb_typeof(template_variable_mapping) = 'object'::text)) not valid;

alter table "public"."campaigns" validate constraint "campaigns_template_variable_mapping_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.enforce_campaign_csv_recipient()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if not exists (
    select 1
    from public.campaigns
    where id = new.campaign_id
      and organization_id = new.organization_id
      and audience_type = 'csv_upload'::public.campaign_audience_type
  ) then
    raise exception 'CSV recipients require a CSV upload campaign in the same organization'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_campaign_draft_rules()
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
    raise exception 'Campaign account must be a WhatsApp address in the same organization'
      using errcode = '23514';
  end if;

  if new.created_by is not null and not exists (
    select 1
    from public.agents
    where id = new.created_by
      and organization_id = new.organization_id
  ) then
    raise exception 'Campaign creator must belong to the campaign organization'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_audience_count(p_organization_id uuid, p_campaign_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  audience_count bigint;
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

  select * into campaign
  from public.campaigns
  where id = p_campaign_id
    and organization_id = p_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign not found';
  end if;

  case campaign.audience_type
    when 'all_contacts'::public.campaign_audience_type then
      select count(*) into audience_count
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active';

    when 'active_24h'::public.campaign_audience_type then
      select count(*) into audience_count
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
        and exists (
          select 1
          from public.messages m
          where m.organization_id = ca.organization_id
            and m.organization_address = campaign.organization_address
            and m.contact_address = ca.address
            and m.service = 'whatsapp'::public.service
            and m.direction = 'incoming'::public.direction
            and m.timestamp >= now() - interval '24 hours'
        );

    when 'csv_upload'::public.campaign_audience_type then
      select count(*) into audience_count
      from public.campaign_csv_recipients r
      where r.organization_id = p_organization_id
        and r.campaign_id = p_campaign_id;
  end case;

  return audience_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_audience_preview(p_organization_id uuid, p_campaign_id uuid, p_limit integer DEFAULT 20)
 RETURNS TABLE(contact_address text, name text, variables jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  normalized_limit integer;
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

  select * into campaign
  from public.campaigns
  where id = p_campaign_id
    and organization_id = p_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign not found';
  end if;

  normalized_limit := least(greatest(coalesce(p_limit, 20), 1), 500);

  case campaign.audience_type
    when 'all_contacts'::public.campaign_audience_type then
      return query
      select ca.address, c.name, '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
      order by c.name nulls last, ca.address
      limit normalized_limit;

    when 'active_24h'::public.campaign_audience_type then
      return query
      select ca.address, c.name, '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
        and exists (
          select 1
          from public.messages m
          where m.organization_id = ca.organization_id
            and m.organization_address = campaign.organization_address
            and m.contact_address = ca.address
            and m.service = 'whatsapp'::public.service
            and m.direction = 'incoming'::public.direction
            and m.timestamp >= now() - interval '24 hours'
        )
      order by c.name nulls last, ca.address
      limit normalized_limit;

    when 'csv_upload'::public.campaign_audience_type then
      return query
      select r.contact_address, r.name, r.variables
      from public.campaign_csv_recipients r
      where r.organization_id = p_organization_id
        and r.campaign_id = p_campaign_id
      order by r.name nulls last, r.contact_address
      limit normalized_limit;
  end case;
end;
$function$
;

grant delete on table "public"."campaign_csv_recipients" to "anon";

grant insert on table "public"."campaign_csv_recipients" to "anon";

grant references on table "public"."campaign_csv_recipients" to "anon";

grant select on table "public"."campaign_csv_recipients" to "anon";

grant trigger on table "public"."campaign_csv_recipients" to "anon";

grant truncate on table "public"."campaign_csv_recipients" to "anon";

grant update on table "public"."campaign_csv_recipients" to "anon";

grant delete on table "public"."campaign_csv_recipients" to "authenticated";

grant insert on table "public"."campaign_csv_recipients" to "authenticated";

grant references on table "public"."campaign_csv_recipients" to "authenticated";

grant select on table "public"."campaign_csv_recipients" to "authenticated";

grant trigger on table "public"."campaign_csv_recipients" to "authenticated";

grant truncate on table "public"."campaign_csv_recipients" to "authenticated";

grant update on table "public"."campaign_csv_recipients" to "authenticated";

grant delete on table "public"."campaign_csv_recipients" to "service_role";

grant insert on table "public"."campaign_csv_recipients" to "service_role";

grant references on table "public"."campaign_csv_recipients" to "service_role";

grant select on table "public"."campaign_csv_recipients" to "service_role";

grant trigger on table "public"."campaign_csv_recipients" to "service_role";

grant truncate on table "public"."campaign_csv_recipients" to "service_role";

grant update on table "public"."campaign_csv_recipients" to "service_role";

grant delete on table "public"."campaigns" to "anon";

grant insert on table "public"."campaigns" to "anon";

grant references on table "public"."campaigns" to "anon";

grant select on table "public"."campaigns" to "anon";

grant trigger on table "public"."campaigns" to "anon";

grant truncate on table "public"."campaigns" to "anon";

grant update on table "public"."campaigns" to "anon";

grant delete on table "public"."campaigns" to "authenticated";

grant insert on table "public"."campaigns" to "authenticated";

grant references on table "public"."campaigns" to "authenticated";

grant select on table "public"."campaigns" to "authenticated";

grant trigger on table "public"."campaigns" to "authenticated";

grant truncate on table "public"."campaigns" to "authenticated";

grant update on table "public"."campaigns" to "authenticated";

grant delete on table "public"."campaigns" to "service_role";

grant insert on table "public"."campaigns" to "service_role";

grant references on table "public"."campaigns" to "service_role";

grant select on table "public"."campaigns" to "service_role";

grant trigger on table "public"."campaigns" to "service_role";

grant truncate on table "public"."campaigns" to "service_role";

grant update on table "public"."campaigns" to "service_role";


  create policy "members can manage their orgs campaign CSV recipients"
  on "public"."campaign_csv_recipients"
  as permissive
  for all
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can manage their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for all
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)))
with check ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));


CREATE TRIGGER enforce_campaign_csv_recipient BEFORE INSERT OR UPDATE OF organization_id, campaign_id ON public.campaign_csv_recipients FOR EACH ROW EXECUTE FUNCTION public.enforce_campaign_csv_recipient();

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.campaign_csv_recipients FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE TRIGGER enforce_campaign_draft_rules BEFORE INSERT OR UPDATE OF organization_id, organization_address, created_by ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.enforce_campaign_draft_rules();

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');
