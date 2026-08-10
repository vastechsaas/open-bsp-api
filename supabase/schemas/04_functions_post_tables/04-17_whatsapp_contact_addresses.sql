-- Webhook-only bulk upsert. The conflict update deliberately excludes
-- contact_id so retries and concurrent webhook deliveries cannot unlink or
-- replace the canonical Contact created by the first-inbound triggers.
create function public.upsert_whatsapp_contact_addresses(
  p_addresses jsonb
) returns void
language sql
set search_path = ''
as $$
  insert into public.contacts_addresses (
    organization_id,
    service,
    address,
    extra
  )
  select
    input.organization_id,
    'whatsapp'::public.service,
    input.address,
    coalesce(input.extra, '{}'::jsonb)
  from jsonb_to_recordset(coalesce(p_addresses, '[]'::jsonb)) as input(
    organization_id uuid,
    address text,
    extra jsonb
  )
  on conflict (organization_id, address) do update
  set extra = excluded.extra;
$$;

revoke all on function public.upsert_whatsapp_contact_addresses(jsonb)
from public, anon, authenticated;

grant execute on function public.upsert_whatsapp_contact_addresses(jsonb)
to service_role;
