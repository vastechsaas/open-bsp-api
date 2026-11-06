create function public.claim_campaign_media_cache(
  p_organization_id uuid,p_organization_address text,p_storage_uri text,p_stale_media_id text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
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
$$;

create function public.complete_campaign_media_cache(
  p_organization_id uuid,p_organization_address text,p_storage_uri text,p_token uuid,p_media_id text
) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_media_id is null or p_media_id !~ '^[0-9]{1,100}$' then
    raise exception 'Invalid Meta media reference' using errcode='22023'; end if;
  update public.campaign_media_cache set media_id=p_media_id,uploaded_at=clock_timestamp(),
    lease_token=null,lease_expires_at=null
    where organization_id=p_organization_id and organization_address=p_organization_address
      and storage_uri=p_storage_uri and lease_token=p_token and lease_expires_at>clock_timestamp();
  return found;
end;
$$;

create function public.release_campaign_media_cache(
  p_organization_id uuid,p_organization_address text,p_storage_uri text,p_token uuid
) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.campaign_media_cache set lease_token=null,lease_expires_at=null
    where organization_id=p_organization_id and organization_address=p_organization_address
      and storage_uri=p_storage_uri and lease_token=p_token;
  return found;
end;
$$;
revoke all on function public.claim_campaign_media_cache(uuid,text,text,text),
  public.complete_campaign_media_cache(uuid,text,text,uuid,text),
  public.release_campaign_media_cache(uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.claim_campaign_media_cache(uuid,text,text,text),
  public.complete_campaign_media_cache(uuid,text,text,uuid,text),
  public.release_campaign_media_cache(uuid,text,text,uuid) to service_role;
