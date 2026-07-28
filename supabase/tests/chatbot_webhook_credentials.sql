begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(7);

insert into public.organizations (id, name, extra)
values
  ('17000000-0000-4000-8000-000000000001', 'Webhook Org A', '{}'),
  ('17000000-0000-4000-8000-000000000002', 'Webhook Org B', '{}');

create temporary table created_credential as
select *
from public.create_chatbot_webhook_credential(
  '17000000-0000-4000-8000-000000000001',
  'CRM token',
  '{"Authorization":"Bearer protected","X-Account":"north"}'::jsonb,
  null
);

select is(
  (select count(*) from created_credential),
  1::bigint,
  'credential metadata is created'
);

select is(
  (
    select public.resolve_chatbot_webhook_credential(
      '17000000-0000-4000-8000-000000000001',
      id
    )
    from created_credential
  ),
  '{"Authorization":"Bearer protected","X-Account":"north"}'::jsonb,
  'the service-only resolver returns decrypted headers for the same organization'
);

select is(
  (
    select public.resolve_chatbot_webhook_credential(
      '17000000-0000-4000-8000-000000000002',
      id
    )
    from created_credential
  ),
  null::jsonb,
  'cross-organization credential resolution returns nothing'
);

select ok(
  not has_table_privilege(
    'anon',
    'public.chatbot_webhook_credentials',
    'INSERT'
  ),
  'anonymous callers cannot insert credential metadata'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.resolve_chatbot_webhook_credential(uuid, uuid)',
    'EXECUTE'
  ),
  'authenticated callers cannot invoke the secret resolver'
);

create temporary table deleted_vault_secret as
select vault_secret_id
from public.chatbot_webhook_credentials
where id = (select id from created_credential);

delete from public.chatbot_webhook_credentials
where id = (select id from created_credential);

select is(
  (
    select count(*)
    from vault.secrets
    where id = (select vault_secret_id from deleted_vault_secret)
  ),
  0::bigint,
  'deleting credential metadata removes the protected Vault secret'
);

select ok(
  has_table_privilege(
    'service_role',
    'public.chatbot_webhook_credentials',
    'DELETE'
  ),
  'service role can delete credential metadata through the management API'
);

select * from finish();

rollback;
