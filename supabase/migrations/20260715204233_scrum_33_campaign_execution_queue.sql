drop policy "members can manage their orgs campaign CSV recipients" on "public"."campaign_csv_recipients";

drop policy "members can manage their orgs campaign drafts" on "public"."campaigns";

alter table "public"."campaigns" drop constraint "campaigns_status_check";


  create table "public"."campaign_deliveries" (
    "organization_id" uuid not null,
    "campaign_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "contact_address" text not null,
    "name" text,
    "variables" jsonb not null default '{}'::jsonb,
    "status" text not null default 'queued'::text,
    "attempts" integer not null default 0,
    "external_id" text,
    "error" jsonb,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."campaign_deliveries" enable row level security;

CREATE UNIQUE INDEX campaign_deliveries_campaign_address_key ON public.campaign_deliveries USING btree (campaign_id, contact_address);

CREATE INDEX campaign_deliveries_campaign_status_idx ON public.campaign_deliveries USING btree (campaign_id, status, created_at);

CREATE UNIQUE INDEX campaign_deliveries_external_id_key ON public.campaign_deliveries USING btree (external_id);

CREATE INDEX campaign_deliveries_organization_id_idx ON public.campaign_deliveries USING btree (organization_id);

CREATE UNIQUE INDEX campaign_deliveries_pkey ON public.campaign_deliveries USING btree (id);

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_pkey" PRIMARY KEY using index "campaign_deliveries_pkey";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_attempts_check" CHECK ((attempts >= 0)) not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_attempts_check";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_campaign_address_key" UNIQUE using index "campaign_deliveries_campaign_address_key";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_campaign_fkey" FOREIGN KEY (organization_id, campaign_id) REFERENCES public.campaigns(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_campaign_fkey";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_contact_address_check" CHECK ((length(btrim(contact_address)) > 0)) not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_contact_address_check";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_external_id_key" UNIQUE using index "campaign_deliveries_external_id_key";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'accepted'::text, 'failed'::text]))) not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_status_check";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_variables_check" CHECK ((jsonb_typeof(variables) = 'object'::text)) not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_variables_check";

alter table "public"."campaigns" add constraint "campaigns_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'queued'::text, 'running'::text, 'completed'::text, 'failed'::text]))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.start_campaign(p_organization_id uuid, p_campaign_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  component jsonb;
  variable_match text[];
  mapping_key text;
  mapping_value text;
  csv_column text;
  queued_count bigint;
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
    and organization_id = p_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign not found';
  end if;

  if campaign.status <> 'draft' then
    raise exception using
      errcode = '23514',
      message = 'campaign has already been started';
  end if;

  if not exists (
    select 1
    from public.organizations_addresses oa
    where oa.organization_id = p_organization_id
      and oa.address = campaign.organization_address
      and oa.service = 'whatsapp'::public.service
      and oa.status = 'connected'
  ) then
    raise exception using
      errcode = '23514',
      message = 'campaign WhatsApp account is not connected';
  end if;

  if campaign.template->>'status' <> 'APPROVED' then
    raise exception using
      errcode = '23514',
      message = 'campaign template is not approved';
  end if;

  if jsonb_typeof(campaign.template->'components') = 'array' then
    for component in
      select value
      from jsonb_array_elements(campaign.template->'components')
      where value->>'type' in ('HEADER', 'BODY')
    loop
      for variable_match in
        select regexp_matches(
          coalesce(component->>'text', ''),
          '\{\{\s*([0-9]+)\s*\}\}',
          'g'
        )
      loop
        mapping_key := lower(component->>'type') || '.' || variable_match[1];
        mapping_value := campaign.template_variable_mapping->>mapping_key;

        if coalesce(btrim(mapping_value), '') = '' then
          raise exception using
            errcode = '23514',
            message = format('campaign template variable %s is not mapped', mapping_key);
        end if;

        if mapping_value in ('contact.name', 'contact.address') then
          continue;
        end if;

        if campaign.audience_type = 'csv_upload'::public.campaign_audience_type
          and mapping_value like 'csv.%'
        then
          csv_column := substring(mapping_value from 5);
          if coalesce(csv_column, '') <> '' and exists (
            select 1
            from public.campaign_csv_recipients r
            where r.organization_id = p_organization_id
              and r.campaign_id = p_campaign_id
              and r.variables ? csv_column
          ) then
            continue;
          end if;
        end if;

        raise exception using
          errcode = '23514',
          message = format('campaign template variable %s has an invalid mapping', mapping_key);
      end loop;
    end loop;
  end if;

  case campaign.audience_type
    when 'all_contacts'::public.campaign_audience_type then
      insert into public.campaign_deliveries (
        organization_id,
        campaign_id,
        contact_address,
        name,
        variables
      )
      select distinct
        p_organization_id,
        p_campaign_id,
        ca.address,
        c.name,
        '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
      on conflict (campaign_id, contact_address) do nothing;

    when 'active_24h'::public.campaign_audience_type then
      insert into public.campaign_deliveries (
        organization_id,
        campaign_id,
        contact_address,
        name,
        variables
      )
      select distinct
        p_organization_id,
        p_campaign_id,
        ca.address,
        c.name,
        '{}'::jsonb
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
      on conflict (campaign_id, contact_address) do nothing;

    when 'csv_upload'::public.campaign_audience_type then
      insert into public.campaign_deliveries (
        organization_id,
        campaign_id,
        contact_address,
        name,
        variables
      )
      select
        r.organization_id,
        r.campaign_id,
        r.contact_address,
        r.name,
        r.variables
      from public.campaign_csv_recipients r
      where r.organization_id = p_organization_id
        and r.campaign_id = p_campaign_id
      on conflict (campaign_id, contact_address) do nothing;
  end case;

  get diagnostics queued_count = row_count;

  if queued_count = 0 then
    raise exception using
      errcode = '23514',
      message = 'campaign audience is empty';
  end if;

  update public.campaigns
  set status = 'queued'
  where id = p_campaign_id
    and organization_id = p_organization_id;

  return queued_count;
end;
$function$
;

revoke execute on function public.start_campaign(uuid, uuid) from public;

grant execute on function public.start_campaign(uuid, uuid)
to anon, authenticated, service_role;

grant delete on table "public"."campaign_deliveries" to "anon";

grant insert on table "public"."campaign_deliveries" to "anon";

grant references on table "public"."campaign_deliveries" to "anon";

grant select on table "public"."campaign_deliveries" to "anon";

grant trigger on table "public"."campaign_deliveries" to "anon";

grant truncate on table "public"."campaign_deliveries" to "anon";

grant update on table "public"."campaign_deliveries" to "anon";

grant delete on table "public"."campaign_deliveries" to "authenticated";

grant insert on table "public"."campaign_deliveries" to "authenticated";

grant references on table "public"."campaign_deliveries" to "authenticated";

grant select on table "public"."campaign_deliveries" to "authenticated";

grant trigger on table "public"."campaign_deliveries" to "authenticated";

grant truncate on table "public"."campaign_deliveries" to "authenticated";

grant update on table "public"."campaign_deliveries" to "authenticated";

grant delete on table "public"."campaign_deliveries" to "service_role";

grant insert on table "public"."campaign_deliveries" to "service_role";

grant references on table "public"."campaign_deliveries" to "service_role";

grant select on table "public"."campaign_deliveries" to "service_role";

grant trigger on table "public"."campaign_deliveries" to "service_role";

grant truncate on table "public"."campaign_deliveries" to "service_role";

grant update on table "public"."campaign_deliveries" to "service_role";


  create policy "members can create CSV recipients for campaign drafts"
  on "public"."campaign_csv_recipients"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))));



  create policy "members can delete CSV recipients for campaign drafts"
  on "public"."campaign_csv_recipients"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))));



  create policy "members can read their orgs campaign CSV recipients"
  on "public"."campaign_csv_recipients"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can update CSV recipients for campaign drafts"
  on "public"."campaign_csv_recipients"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))))
with check (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))));



  create policy "members can read their orgs campaign deliveries"
  on "public"."campaign_deliveries"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can create their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (status = 'draft'::text)));



  create policy "members can delete their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (status = 'draft'::text)));



  create policy "members can read their orgs campaigns"
  on "public"."campaigns"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can update their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (status = 'draft'::text)))
with check (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (status = 'draft'::text)));


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.campaign_deliveries FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');
