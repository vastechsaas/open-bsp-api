begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra)
values (
  'b1000000-0000-4000-8000-000000000001',
  'Inbound Contact Org',
  '{}'
);

insert into public.organizations_addresses (
  organization_id, service, address, status, extra
) values (
  'b1000000-0000-4000-8000-000000000001',
  'whatsapp',
  '100000000001',
  'connected',
  '{}'
);

-- A genuinely new inbound WhatsApp identity creates and links one Contact.
insert into public.contacts_addresses (
  organization_id, service, address, extra
) values (
  'b1000000-0000-4000-8000-000000000001',
  'whatsapp',
  '923001111111',
  '{"name":"Ali Meta","phone_number":"923001111111","has_inbound_message":true}'
);

select ok(
  (
    select contact_id is not null
    from public.contacts_addresses
    where organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address = '923001111111'
  ),
  'the first inbound WhatsApp message links a canonical Contact'
);

select is(
  (
    select contact.name
    from public.contacts_addresses as address
    join public.contacts as contact on contact.id = address.contact_id
    where address.organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address.address = '923001111111'
  ),
  'Ali Meta'::text,
  'the initial Contact name comes from the Meta profile'
);

-- Agent edits remain authoritative when Meta later sends another profile name.
update public.contacts
set name = 'Ali Agent Edited', email = 'ali@example.test'
where id = (
  select contact_id
  from public.contacts_addresses
  where organization_id = 'b1000000-0000-4000-8000-000000000001'
    and address = '923001111111'
);

update public.contacts_addresses
set extra = '{"name":"Ali Meta Changed","has_inbound_message":true}'
where organization_id = 'b1000000-0000-4000-8000-000000000001'
  and address = '923001111111';

select results_eq(
  $$
    select contact.name, contact.email
    from public.contacts_addresses as address
    join public.contacts as contact on contact.id = address.contact_id
    where address.organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address.address = '923001111111'
  $$,
  $$ values ('Ali Agent Edited'::text, 'ali@example.test'::text) $$,
  'later Meta metadata never overwrites agent-edited Contact fields'
);

-- A webhook retry follows the internal bulk conflict path and creates nothing
-- else while preserving the existing contact_id.
select public.upsert_whatsapp_contact_addresses(
  '[{
    "organization_id":"b1000000-0000-4000-8000-000000000001",
    "address":"923001111111",
    "extra":{"name":"Ali Meta Changed","has_inbound_message":true}
  }]'
);

select is(
  (
    select count(*)
    from public.contacts
    where organization_id = 'b1000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'a retried first-message upsert does not create a duplicate Contact'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.upsert_whatsapp_contact_addresses(jsonb)',
    'execute'
  ),
  'normal clients cannot call the webhook-only address upsert'
);

-- An address created earlier by another event is linked on its first inbound
-- transition, using username when Meta does not provide a phone/name.
insert into public.contacts_addresses (
  organization_id, service, address, extra
) values (
  'b1000000-0000-4000-8000-000000000001',
  'whatsapp',
  'US.ali-username',
  '{"username":"ali.username","address_type":"bsuid"}'
);

update public.contacts_addresses
set extra = '{"has_inbound_message":true}'
where organization_id = 'b1000000-0000-4000-8000-000000000001'
  and address = 'US.ali-username';

select is(
  (
    select contact.name
    from public.contacts_addresses as address
    join public.contacts as contact on contact.id = address.contact_id
    where address.organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address.address = 'US.ali-username'
  ),
  'ali.username'::text,
  'an existing unlinked address is linked only on its first inbound transition'
);

-- Status/outgoing-only WhatsApp identities and Instagram identities are skipped.
insert into public.contacts_addresses (
  organization_id, service, address, extra
) values
  (
    'b1000000-0000-4000-8000-000000000001',
    'whatsapp',
    '923002222222',
    '{"name":"Status Only"}'
  ),
  (
    'b1000000-0000-4000-8000-000000000001',
    'instagram',
    'instagram-user-1',
    '{"name":"Instagram User","has_inbound_message":true}'
  );

select results_eq(
  $$
    select address, contact_id is null
    from public.contacts_addresses
    where organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address in ('923002222222', 'instagram-user-1')
    order by address
  $$,
  $$
    values
      ('923002222222'::text, true),
      ('instagram-user-1'::text, true)
  $$,
  'non-inbound WhatsApp and all Instagram identities remain unlinked'
);

-- A manually linked Contact remains unchanged when the marker first appears.
insert into public.contacts (
  id, organization_id, name, email, company
) values (
  'b1300000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000001',
  'Existing Customer',
  'existing@example.test',
  'Existing Company'
);

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, extra
) values (
  'b1000000-0000-4000-8000-000000000001',
  'b1300000-0000-4000-8000-000000000001',
  'whatsapp',
  '923003333333',
  '{"name":"Existing Meta Name"}'
);

update public.contacts_addresses
set extra = '{"has_inbound_message":true}'
where organization_id = 'b1000000-0000-4000-8000-000000000001'
  and address = '923003333333';

select results_eq(
  $$
    select address.contact_id, contact.name, contact.email, contact.company
    from public.contacts_addresses as address
    join public.contacts as contact on contact.id = address.contact_id
    where address.organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address.address = '923003333333'
  $$,
  $$
    values (
      'b1300000-0000-4000-8000-000000000001'::uuid,
      'Existing Customer'::text,
      'existing@example.test'::text,
      'Existing Company'::text
    )
  $$,
  'the first inbound marker preserves an existing Contact link and details'
);

-- A Meta BSUID change is an identity transition, not a new customer.
insert into public.contacts (
  id, organization_id, name
) values (
  'b1300000-0000-4000-8000-000000000002',
  'b1000000-0000-4000-8000-000000000001',
  'Number Changed Customer'
);

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, status, extra
) values (
  'b1000000-0000-4000-8000-000000000001',
  'b1300000-0000-4000-8000-000000000002',
  'whatsapp',
  '923003333334',
  'inactive',
  '{"bsuid":"US.old","replaced_by_bsuid":"US.current"}'
);

insert into public.contacts_addresses (
  organization_id, service, address, extra
) values (
  'b1000000-0000-4000-8000-000000000001',
  'whatsapp',
  'US.current',
  '{"name":"Changed Meta Name","bsuid":"US.current","has_inbound_message":true}'
);

select is(
  (
    select contact_id
    from public.contacts_addresses
    where organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address = 'US.current'
  ),
  'b1300000-0000-4000-8000-000000000002'::uuid,
  'the first message after a BSUID change reuses the existing Contact'
);

-- Reproduce the migration backfill over one inbound and one outgoing-only row.
insert into public.contacts_addresses (
  organization_id, service, address, extra
) values
  (
    'b1000000-0000-4000-8000-000000000001',
    'whatsapp',
    '923004444444',
    '{"name":"Legacy Inbound"}'
  ),
  (
    'b1000000-0000-4000-8000-000000000001',
    'whatsapp',
    '923005555555',
    '{"name":"Legacy Outgoing"}'
  );

insert into public.conversations (
  id, organization_id, service, organization_address, contact_address
) values
  (
    'b1400000-0000-4000-8000-000000000001',
    'b1000000-0000-4000-8000-000000000001',
    'whatsapp',
    '100000000001',
    '923004444444'
  ),
  (
    'b1400000-0000-4000-8000-000000000002',
    'b1000000-0000-4000-8000-000000000001',
    'whatsapp',
    '100000000001',
    '923005555555'
  );

insert into public.messages (
  organization_id, conversation_id, external_id, direction,
  contact_address, service, organization_address, content, status
) values
  (
    'b1000000-0000-4000-8000-000000000001',
    'b1400000-0000-4000-8000-000000000001',
    'wamid.backfill-incoming',
    'incoming',
    '923004444444',
    'whatsapp',
    '100000000001',
    '{"version":"1","type":"text","kind":"text","text":"Hello"}',
    '{"received":"2026-08-10T00:00:00Z"}'
  ),
  (
    'b1000000-0000-4000-8000-000000000001',
    'b1400000-0000-4000-8000-000000000002',
    'wamid.backfill-outgoing',
    'outgoing',
    '923005555555',
    'whatsapp',
    '100000000001',
    '{"version":"1","type":"text","kind":"text","text":"Welcome"}',
    '{"sent":"2026-08-10T00:00:00Z"}'
  );

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

select results_eq(
  $$
    select address, contact_id is not null
    from public.contacts_addresses
    where organization_id = 'b1000000-0000-4000-8000-000000000001'
      and address in ('923004444444', '923005555555')
    order by address
  $$,
  $$
    values
      ('923004444444'::text, true),
      ('923005555555'::text, false)
  $$,
  'backfill links inbound WhatsApp customers and skips outgoing-only addresses'
);

select * from finish();
rollback;
