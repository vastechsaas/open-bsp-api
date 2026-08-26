create table public.chatbot_integration_raw_events (
  id uuid not null default gen_random_uuid(),
  payload_sha256 text not null,
  queue_name text not null,
  raw_payload text not null,
  received_at timestamp with time zone not null default now(),
  constraint chatbot_integration_raw_events_pkey primary key (id),
  constraint chatbot_integration_raw_events_payload_sha256_key unique (payload_sha256),
  constraint chatbot_integration_raw_events_payload_sha256_check
    check (payload_sha256 ~ '^[a-f0-9]{64}$')
);

create index chatbot_integration_raw_events_received_at_idx
on public.chatbot_integration_raw_events (received_at desc);
