  create table "public"."campaign_media_cache" (
    "organization_id" uuid not null,
    "organization_address" text not null,
    "storage_uri" text not null,
    "media_id" text,
    "uploaded_at" timestamp with time zone,
    "lease_token" uuid,
    "lease_expires_at" timestamp with time zone
      );


alter table "public"."campaign_media_cache" enable row level security;

CREATE UNIQUE INDEX campaign_media_cache_pkey ON public.campaign_media_cache USING btree (organization_id, organization_address, storage_uri);

alter table "public"."campaign_media_cache" add constraint "campaign_media_cache_pkey" PRIMARY KEY using index "campaign_media_cache_pkey";

alter table "public"."campaign_media_cache" add constraint "campaign_media_cache_check" CHECK ((storage_uri ~ (('^internal://media/organizations/'::text || (organization_id)::text) || '/attachments/[A-Za-z0-9_-]{43}$'::text))) not valid;

alter table "public"."campaign_media_cache" validate constraint "campaign_media_cache_check";

alter table "public"."campaign_media_cache" add constraint "campaign_media_cache_check1" CHECK (((lease_token IS NULL) = (lease_expires_at IS NULL))) not valid;

alter table "public"."campaign_media_cache" validate constraint "campaign_media_cache_check1";

alter table "public"."campaign_media_cache" add constraint "campaign_media_cache_media_id_check" CHECK (((media_id IS NULL) OR (media_id ~ '^[0-9]{1,100}$'::text))) not valid;

alter table "public"."campaign_media_cache" validate constraint "campaign_media_cache_media_id_check";

alter table "public"."campaign_media_cache" add constraint "campaign_media_cache_organization_id_organization_address_fkey" FOREIGN KEY (organization_id, organization_address) REFERENCES public.organizations_addresses(organization_id, address) ON DELETE CASCADE not valid;

alter table "public"."campaign_media_cache" validate constraint "campaign_media_cache_organization_id_organization_address_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.claim_campaign_media_cache(p_organization_id uuid, p_organization_address text, p_storage_uri text, p_stale_media_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare cached public.campaign_media_cache; token uuid;
begin
  if not public.is_organization_active(p_organization_id) or not exists(
    select 1 from public.organizations_addresses
    where organization_id=p_organization_id and address=p_organization_address
      and service='whatsapp' and status='connected'
  ) then raise exception 'Campaign sending account is unavailable' using errcode='42501'; end if;
  insert into public.campaign_media_cache(organization_id,organization_address,storage_uri)
    values(p_organization_id,p_organization_address,p_storage_uri) on conflict do nothing;
  select * into strict cached from public.campaign_media_cache
    where organization_id=p_organization_id and organization_address=p_organization_address
      and storage_uri=p_storage_uri for update;
  if cached.lease_expires_at>clock_timestamp() then return jsonb_build_object('state','busy'); end if;
  -- A stale failure cannot invalidate a replacement uploaded by another worker.
  if cached.media_id is not null and
    (p_stale_media_id is null or cached.media_id<>p_stale_media_id) then
    return jsonb_build_object('state','ready','media_id',cached.media_id);
  end if;
  token:=gen_random_uuid();
  update public.campaign_media_cache set media_id=null,uploaded_at=null,
    lease_token=token,lease_expires_at=clock_timestamp()+interval '2 minutes'
    where organization_id=p_organization_id and organization_address=p_organization_address and storage_uri=p_storage_uri;
  return jsonb_build_object('state','claimed','lease_token',token);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.complete_campaign_media_cache(p_organization_id uuid, p_organization_address text, p_storage_uri text, p_token uuid, p_media_id text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_media_id is null or p_media_id !~ '^[0-9]{1,100}$' then
    raise exception 'Invalid Meta media reference' using errcode='22023'; end if;
  update public.campaign_media_cache set media_id=p_media_id,uploaded_at=clock_timestamp(),
    lease_token=null,lease_expires_at=null
    where organization_id=p_organization_id and organization_address=p_organization_address
      and storage_uri=p_storage_uri and lease_token=p_token and lease_expires_at>clock_timestamp();
  return found;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.release_campaign_media_cache(p_organization_id uuid, p_organization_address text, p_storage_uri text, p_token uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.campaign_media_cache set lease_token=null,lease_expires_at=null
    where organization_id=p_organization_id and organization_address=p_organization_address
      and storage_uri=p_storage_uri and lease_token=p_token;
  return found;
end;
$function$
;

grant delete on table "public"."campaign_media_cache" to "service_role";

grant insert on table "public"."campaign_media_cache" to "service_role";

grant references on table "public"."campaign_media_cache" to "service_role";

grant select on table "public"."campaign_media_cache" to "service_role";

grant trigger on table "public"."campaign_media_cache" to "service_role";

grant truncate on table "public"."campaign_media_cache" to "service_role";

grant update on table "public"."campaign_media_cache" to "service_role";

-- Preserve schema-source worker-only ACLs omitted by the diff generator.
revoke all on public.campaign_media_cache from public,anon,authenticated;
revoke all on function public.claim_campaign_media_cache(uuid,text,text,text),
  public.complete_campaign_media_cache(uuid,text,text,uuid,text),
  public.release_campaign_media_cache(uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.claim_campaign_media_cache(uuid,text,text,text),
  public.complete_campaign_media_cache(uuid,text,text,uuid,text),
  public.release_campaign_media_cache(uuid,text,text,uuid) to service_role;


