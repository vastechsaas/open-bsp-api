set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.manage_contact_on_first_inbound()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  created_contact_id uuid;
  contact_name text;
begin
  if nullif(btrim(new.extra->>'bsuid'), '') is not null then
    select address.contact_id
    into created_contact_id
    from public.contacts_addresses as address
    where address.organization_id = new.organization_id
      and address.service = 'whatsapp'::public.service
      and address.address <> new.address
      and address.contact_id is not null
      and address.extra->>'replaced_by_bsuid' = new.extra->>'bsuid'
    order by address.updated_at desc
    limit 1;
  end if;

  if created_contact_id is null then
    contact_name := coalesce(
      nullif(btrim(new.extra->>'name'), ''),
      nullif(btrim(new.extra->>'username'), ''),
      nullif(btrim(new.extra->>'phone_number'), ''),
      new.address
    );

    insert into public.contacts (organization_id, name)
    values (new.organization_id, contact_name)
    returning id into created_contact_id;
  end if;

  if tg_op = 'UPDATE' then
    new.contact_id := created_contact_id;
    return new;
  end if;

  update public.contacts_addresses
  set contact_id = created_contact_id
  where organization_id = new.organization_id
    and address = new.address
    and contact_id is null;

  return new;
end;
$function$
;

CREATE TRIGGER create_contact_on_first_inbound_insert AFTER INSERT ON public.contacts_addresses FOR EACH ROW WHEN (((new.service = 'whatsapp'::public.service) AND (new.contact_id IS NULL) AND ((new.extra ->> 'has_inbound_message'::text) = 'true'::text))) EXECUTE FUNCTION public.manage_contact_on_first_inbound();

CREATE TRIGGER zz_create_contact_on_first_inbound_update BEFORE UPDATE ON public.contacts_addresses FOR EACH ROW WHEN (((new.service = 'whatsapp'::public.service) AND (new.contact_id IS NULL) AND ((old.extra ->> 'has_inbound_message'::text) IS DISTINCT FROM 'true'::text) AND ((new.extra ->> 'has_inbound_message'::text) = 'true'::text))) EXECUTE FUNCTION public.manage_contact_on_first_inbound();

CREATE OR REPLACE FUNCTION public.upsert_whatsapp_contact_addresses(p_addresses jsonb)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
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
$function$
;

revoke all on function public.upsert_whatsapp_contact_addresses(jsonb)
from public, anon, authenticated;

grant execute on function public.upsert_whatsapp_contact_addresses(jsonb)
to service_role;

-- Backfill only existing, unlinked WhatsApp customers that have actually sent
-- at least one incoming message. The first-marker UPDATE invokes the same
-- trigger used by live webhook ingestion.
update public.contacts_addresses as contact_address
set extra = coalesce(contact_address.extra, '{}'::jsonb)
  || jsonb_build_object('has_inbound_message', true)
where contact_address.service = 'whatsapp'::public.service
  and contact_address.contact_id is null
  and contact_address.extra->>'has_inbound_message' is distinct from 'true'
  and exists (
    select 1
    from public.conversations as conversation
    join public.messages as message
      on message.conversation_id = conversation.id
    where conversation.organization_id = contact_address.organization_id
      and conversation.contact_address = contact_address.address
      and conversation.service = 'whatsapp'::public.service
      and message.direction = 'incoming'::public.direction
      and message.service = 'whatsapp'::public.service
  );
