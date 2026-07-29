begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(27);

insert into public.organizations (id, name, extra)
values
  (
    '17000000-0000-4000-8000-000000000001',
    'External Chatbot Org A',
    '{}'
  ),
  (
    '17000000-0000-4000-8000-000000000002',
    'External Chatbot Org B',
    '{}'
  );

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
)
values
  (
    '17000000-0000-4000-8000-000000000001',
    'whatsapp',
    '15550000001',
    '{}',
    'connected'
  ),
  (
    '17000000-0000-4000-8000-000000000002',
    'whatsapp',
    '15550000002',
    '{}',
    'connected'
  );

select is(
  public.ensure_external_chatbot_agent(
    '17000000-0000-4000-8000-000000000001',
    'psdf',
    'PSDF'
  ),
  public.ensure_external_chatbot_agent(
    '17000000-0000-4000-8000-000000000001',
    'psdf',
    'Ignored Later Name'
  ),
  'external chatbot sender resolution is idempotent'
);

select is(
  (
    select count(*)
    from public.agents
    where organization_id = '17000000-0000-4000-8000-000000000001'
      and ai = true
      and extra->>'kind' = 'external_chatbot'
      and extra->>'integration_key' = 'psdf'
  ),
  1::bigint,
  'one organization has one sender per external chatbot key'
);

select isnt(
  public.ensure_external_chatbot_agent(
    '17000000-0000-4000-8000-000000000001',
    'psdf',
    'PSDF'
  ),
  public.ensure_external_chatbot_agent(
    '17000000-0000-4000-8000-000000000002',
    'psdf',
    'PSDF'
  ),
  'the same external chatbot key is isolated by organization'
);

select is(
  (
    select name
    from public.agents
    where organization_id = '17000000-0000-4000-8000-000000000001'
      and extra->>'kind' = 'external_chatbot'
      and extra->>'integration_key' = 'psdf'
  ),
  'PSDF'::text,
  'the first supplied tenant chatbot name is retained'
);

select throws_ok(
  $$
    select public.ensure_external_chatbot_agent(
      '17000000-0000-4000-8000-000000000001',
      'Invalid Key',
      'Invalid'
    )
  $$,
  '22023',
  'external chatbot key is invalid',
  'invalid external chatbot keys are rejected'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.ensure_external_chatbot_agent(uuid,text,text)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.ensure_external_chatbot_agent(uuid,text,text)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'public.ensure_external_chatbot_agent(uuid,text,text)',
    'EXECUTE'
  ),
  'only service-role callers can ensure external chatbot senders'
);

select is(
  (
    select outcome
    from public.record_external_chatbot_reply(
      '17000000-0000-4000-8000-000000000001',
      public.ensure_external_chatbot_agent(
        '17000000-0000-4000-8000-000000000001',
        'psdf',
        'PSDF'
      ),
      '15550000001',
      '923000000001',
      'wamid.external-1',
      '2026-07-29T12:00:00+00',
      '{
        "version":"1",
        "re_message_id":"wamid.customer-1",
        "type":"text",
        "kind":"text",
        "text":"Welcome to PSDF"
      }'
    )
  ),
  'stored'::text,
  'a successful external chatbot reply is stored'
);

select is(
  (
    select direction::text
    from public.messages
    where external_id = 'wamid.external-1'
  ),
  'outgoing'::text,
  'the stored reply is outgoing'
);

select is(
  (
    select agent.name
    from public.messages as message
    join public.agents as agent on agent.id = message.agent_id
    where message.external_id = 'wamid.external-1'
  ),
  'PSDF'::text,
  'the stored reply is attributed to the tenant chatbot sender'
);

select ok(
  (
    select status ? 'sent' and not status ? 'pending'
    from public.messages
    where external_id = 'wamid.external-1'
  ),
  'the stored reply is sent and cannot be redispatched'
);

select is(
  (
    select content->>'re_message_id'
    from public.messages
    where external_id = 'wamid.external-1'
  ),
  'wamid.customer-1'::text,
  'optional customer reply context is retained'
);

select is(
  (
    select outcome
    from public.record_external_chatbot_reply(
      '17000000-0000-4000-8000-000000000001',
      public.ensure_external_chatbot_agent(
        '17000000-0000-4000-8000-000000000001',
        'psdf',
        'PSDF'
      ),
      '15550000001',
      '923000000001',
      'wamid.external-1',
      '2026-07-29T12:00:00+00',
      '{
        "version":"1",
        "re_message_id":"wamid.customer-1",
        "type":"text",
        "kind":"text",
        "text":"Welcome to PSDF"
      }'
    )
  ),
  'duplicate'::text,
  'an identical WAMID retry is a successful duplicate'
);

select is(
  (
    select count(*)
    from public.messages
    where external_id = 'wamid.external-1'
  ),
  1::bigint,
  'an identical WAMID retry does not create another row'
);

insert into public.conversations (
  organization_id,
  id,
  service,
  organization_address,
  contact_address
) values (
  '17000000-0000-4000-8000-000000000001',
  '57000000-0000-4000-8000-000000000001',
  'whatsapp',
  '15550000001',
  '923000000002'
);

insert into public.messages (
  organization_id,
  conversation_id,
  external_id,
  direction,
  contact_address,
  service,
  organization_address,
  content,
  status,
  "timestamp"
) values (
  '17000000-0000-4000-8000-000000000001',
  '57000000-0000-4000-8000-000000000001',
  'wamid.status-first',
  'outgoing',
  '923000000002',
  'whatsapp',
  '15550000001',
  '{}',
  '{"delivered":"2026-07-29T12:05:10+00:00"}',
  now()
);

select is(
  (
    select outcome
    from public.record_external_chatbot_reply(
      '17000000-0000-4000-8000-000000000001',
      public.ensure_external_chatbot_agent(
        '17000000-0000-4000-8000-000000000001',
        'psdf',
        'PSDF'
      ),
      '15550000001',
      '923000000002',
      'wamid.status-first',
      '2026-07-29T12:05:00+00',
      '{
        "version":"1",
        "type":"text",
        "kind":"text",
        "text":"Status arrived first"
      }'
    )
  ),
  'merged'::text,
  'reply content merges into an earlier Meta status row'
);

select ok(
  (
    select status ? 'sent' and status ? 'delivered'
    from public.messages
    where external_id = 'wamid.status-first'
  ),
  'sent and delivered statuses survive status-first merging'
);

select is(
  (
    select content->>'text'
    from public.messages
    where external_id = 'wamid.status-first'
  ),
  'Status arrived first'::text,
  'reply content fills an earlier status-only row'
);

select ok(
  not coalesce(
    (
      select extra ? 'paused'
      from public.conversations
      where id = '57000000-0000-4000-8000-000000000001'
    ),
    false
  ),
  'a status-first row does not pause chatbot automation'
);

insert into public.conversations (
  organization_id,
  id,
  service,
  organization_address,
  contact_address
) values (
  '17000000-0000-4000-8000-000000000001',
  '57000000-0000-4000-8000-000000000002',
  'whatsapp',
  '15550000001',
  '923000000003'
);

insert into public.messages (
  organization_id,
  conversation_id,
  external_id,
  direction,
  contact_address,
  service,
  organization_address,
  content,
  status,
  "timestamp"
) values (
  '17000000-0000-4000-8000-000000000001',
  '57000000-0000-4000-8000-000000000002',
  'wamid.human-outgoing',
  'outgoing',
  '923000000003',
  'whatsapp',
  '15550000001',
  '{"version":"1","type":"text","kind":"text","text":"Human reply"}',
  '{"sent":"2026-07-29T12:06:00+00:00"}',
  now()
);

select ok(
  (
    select extra ? 'paused'
    from public.conversations
    where id = '57000000-0000-4000-8000-000000000002'
  ),
  'a real outgoing human message still pauses chatbot automation'
);

select throws_ok(
  $$
    select *
    from public.record_external_chatbot_reply(
      '17000000-0000-4000-8000-000000000002',
      public.ensure_external_chatbot_agent(
        '17000000-0000-4000-8000-000000000002',
        'psdf',
        'PSDF'
      ),
      '15550000002',
      '923000000009',
      'wamid.external-1',
      '2026-07-29T12:00:00+00',
      '{"version":"1","type":"text","kind":"text","text":"Conflict"}'
    )
  $$,
  '23505',
  'WAMID belongs to another message',
  'cross-organization WAMID reuse is rejected'
);

select throws_ok(
  $$
    select *
    from public.record_external_chatbot_reply(
      '17000000-0000-4000-8000-000000000001',
      public.ensure_external_chatbot_agent(
        '17000000-0000-4000-8000-000000000001',
        'psdf',
        'PSDF'
      ),
      '15550000001',
      '923000000001',
      'wamid.external-1',
      '2026-07-29T12:00:00+00',
      '{"version":"1","type":"text","kind":"text","text":"Different"}'
    )
  $$,
  '23505',
  'WAMID already has different message content',
  'conflicting content for an existing WAMID is rejected'
);

do $$
begin
  perform outcome
  from public.record_external_chatbot_reply(
    '17000000-0000-4000-8000-000000000001',
    public.ensure_external_chatbot_agent(
      '17000000-0000-4000-8000-000000000001',
      'psdf',
      'PSDF'
    ),
    '15550000001',
    '923000000001',
    'wamid.external-3',
    '2026-07-29T12:02:00+00',
    '{"version":"1","type":"text","kind":"text","text":"Third"}'
  );

  perform outcome
  from public.record_external_chatbot_reply(
    '17000000-0000-4000-8000-000000000001',
    public.ensure_external_chatbot_agent(
      '17000000-0000-4000-8000-000000000001',
      'psdf',
      'PSDF'
    ),
    '15550000001',
    '923000000001',
    'wamid.external-2',
    '2026-07-29T12:01:00+00',
    '{"version":"1","type":"text","kind":"text","text":"Second"}'
  );
end;
$$;

select is(
  (
    select count(distinct conversation_id)
    from public.messages
    where external_id in (
      'wamid.external-1',
      'wamid.external-2',
      'wamid.external-3'
    )
  ),
  1::bigint,
  'multiple chatbot replies reuse the customer conversation'
);

select is(
  (
    select array_agg(external_id order by "timestamp")
    from public.messages
    where external_id in (
      'wamid.external-1',
      'wamid.external-2',
      'wamid.external-3'
    )
  ),
  array[
    'wamid.external-1',
    'wamid.external-2',
    'wamid.external-3'
  ]::text[],
  'multiple chatbot replies order by their authoritative sent timestamp'
);

do $$
begin
  perform outcome
  from public.record_external_chatbot_reply(
    '17000000-0000-4000-8000-000000000001',
    public.ensure_external_chatbot_agent(
      '17000000-0000-4000-8000-000000000001',
      'psdf',
      'PSDF'
    ),
    '15550000001',
    '923000000001',
    'wamid.button',
    '2026-07-29T12:03:00+00',
    '{
      "version":"1",
      "type":"data",
      "kind":"interactive",
      "data":{
        "type":"button",
        "body":{"text":"Choose"},
        "action":{
          "buttons":[
            {
              "type":"reply",
              "reply":{"id":"support","title":"Support"}
            }
          ]
        }
      }
    }'
  );
end;
$$;

select is(
  (
    select content->'data'->'action'->'buttons'->0->'reply'->>'id'
    from public.messages
    where external_id = 'wamid.button'
  ),
  'support'::text,
  'reply-button IDs are stored unchanged'
);

do $$
begin
  perform outcome
  from public.record_external_chatbot_reply(
    '17000000-0000-4000-8000-000000000001',
    public.ensure_external_chatbot_agent(
      '17000000-0000-4000-8000-000000000001',
      'psdf',
      'PSDF'
    ),
    '15550000001',
    '923000000001',
    'wamid.list',
    '2026-07-29T12:04:00+00',
    '{
      "version":"1",
      "type":"data",
      "kind":"interactive",
      "data":{
        "type":"list",
        "body":{"text":"Choose"},
        "action":{
          "button":"Programs",
          "sections":[
            {
              "title":"Programs",
              "rows":[
                {
                  "id":"digital",
                  "title":"Digital Skills",
                  "description":"Technology courses"
                }
              ]
            }
          ]
        }
      }
    }'
  );
end;
$$;

select is(
  (
    select content->'data'->'action'->'sections'->0->'rows'->0->>'id'
    from public.messages
    where external_id = 'wamid.list'
  ),
  'digital'::text,
  'list row IDs are stored unchanged'
);

select ok(
  not exists (
    select 1
    from public.messages
    where external_id like 'wamid.%'
      and status ? 'pending'
  ),
  'no external chatbot reply contains a pending status'
);

update public.agents
set extra = '{"mode":"inactive"}'
where organization_id = '17000000-0000-4000-8000-000000000002'
  and extra->>'kind' = 'external_chatbot'
  and extra->>'integration_key' = 'psdf';

select throws_ok(
  $$
    select public.ensure_external_chatbot_agent(
      '17000000-0000-4000-8000-000000000002',
      'psdf',
      'PSDF'
    )
  $$,
  '23514',
  'external chatbot sender is inactive',
  'inactive external chatbot senders are rejected'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.record_external_chatbot_reply(uuid,uuid,text,text,text,timestamp with time zone,jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.record_external_chatbot_reply(uuid,uuid,text,text,text,timestamp with time zone,jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'public.record_external_chatbot_reply(uuid,uuid,text,text,text,timestamp with time zone,jsonb)',
    'EXECUTE'
  ),
  'only service-role callers can execute the reply-recording RPC'
);

select * from finish();

rollback;
