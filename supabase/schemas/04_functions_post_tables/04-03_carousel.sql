-- Durable assets are private storage references, never Meta upload handles.
create function public.valid_carousel_assets(p_assets jsonb, p_organization_id uuid, p_allow_empty boolean default false)
returns boolean language plpgsql immutable set search_path = '' as $$
declare asset jsonb; ids text[] := '{}';
begin
  if jsonb_typeof(p_assets) is distinct from 'array' or jsonb_array_length(p_assets) > 10 then return false; end if;
  for asset in select value from jsonb_array_elements(p_assets) loop
    if jsonb_typeof(asset) is distinct from 'object'
      or coalesce(asset->>'card_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or asset->>'card_id' = any(ids) then return false; end if;
    ids := array_append(ids, asset->>'card_id');
    if not asset ? 'storage_uri' and p_allow_empty and asset = jsonb_build_object('card_id', asset->>'card_id') then continue; end if;
    if coalesce(asset->>'storage_uri', '') !~ ('^internal://media/organizations/' || p_organization_id::text || '/attachments/[A-Za-z0-9_-]{43}$')
      or coalesce(asset->>'mime_type', '') not in ('image/jpeg', 'image/png')
      or jsonb_typeof(asset->'file_name') is distinct from 'string'
      or coalesce(asset->>'size', '') !~ '^[0-9]{1,8}$'
    then return false; end if;
    if (asset->>'size')::bigint not between 1 and 5242880 then return false; end if;
  end loop;
  return true;
end;
$$;

-- Used before queueing AND by paginated readiness; direct RPC calls cannot bypass it.
create function public.carousel_campaign_ready(p_template jsonb, p_media jsonb, p_mapping jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
declare carousel jsonb; card jsonb; part jsonb; idx integer := 0; variable text[]; key text;
begin
  select value into carousel from jsonb_array_elements(coalesce(p_template->'components', '[]')) where value->>'type' = 'CAROUSEL';
  if carousel is null then return true; end if;
  if p_template->>'category' is distinct from 'MARKETING'
    or jsonb_typeof(carousel->'cards') is distinct from 'array'
    or jsonb_typeof(p_media) is distinct from 'array' then return false; end if;
  if jsonb_array_length(carousel->'cards') not between 2 and 10
    or jsonb_array_length(p_media) <> jsonb_array_length(carousel->'cards') then return false; end if;
  for card in select value from jsonb_array_elements(carousel->'cards') loop
    if jsonb_array_length(card->'components') <> 3
      or not card->'components' @> '[{"type":"HEADER","format":"IMAGE"}]'
      or not exists (select 1 from jsonb_array_elements(card->'components') p where p->>'type' = 'BODY' and length(btrim(p->>'text')) between 1 and 160)
      or not exists (select 1 from jsonb_array_elements(card->'components') p where p->>'type' = 'BUTTONS'
        and jsonb_array_length(p->'buttons') = 1 and p->'buttons'->0->>'type' = 'URL'
        and length(btrim(p->'buttons'->0->>'text')) between 1 and 25
        and p->'buttons'->0->>'url' like 'https://%')
      or coalesce(p_media->idx->>'card_index', '') <> idx::text then return false; end if;
    for part in select value from jsonb_array_elements(card->'components') loop
      for variable in select regexp_matches(case when part->>'type' = 'BODY' then part->>'text' else part->'buttons'->0->>'url' end, '\{\{\s*([0-9]+)\s*\}\}', 'g') loop
        key := 'carousel.' || idx || case when part->>'type' = 'BODY' then '.body.' || variable[1] else '.button.0.1' end;
        if coalesce(p_mapping->>key, '') !~ '^(contact\.(name|address)|csv\..+)$' then return false; end if;
      end loop;
    end loop;
    idx := idx + 1;
  end loop;
  return true;
exception when others then return false;
end;
$$;
