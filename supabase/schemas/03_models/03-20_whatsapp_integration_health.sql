create table public.whatsapp_integration_health (
  organization_id uuid not null,
  phone_number_id text not null,
  last_check_attempted_at timestamp with time zone,
  last_check_succeeded_at timestamp with time zone,
  token_status text not null default 'unknown',
  token_validated_at timestamp with time zone,
  token_expires_at timestamp with time zone,
  webhook_subscription_status text not null default 'unknown',
  webhook_validated_at timestamp with time zone,
  last_webhook_received_at timestamp with time zone,
  last_webhook_succeeded_at timestamp with time zone,
  last_webhook_error_at timestamp with time zone,
  failure_code text,
  failure_message text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);

alter table only public.whatsapp_integration_health
add constraint whatsapp_integration_health_pkey
primary key (organization_id, phone_number_id);

alter table only public.whatsapp_integration_health
add constraint whatsapp_integration_health_account_fkey
foreign key (organization_id, phone_number_id)
references public.organizations_addresses(organization_id, address)
on delete cascade;

alter table only public.whatsapp_integration_health
add constraint whatsapp_integration_health_token_status_check
check (token_status in ('unknown', 'valid', 'invalid', 'expired', 'error'));

alter table only public.whatsapp_integration_health
add constraint whatsapp_integration_health_webhook_status_check
check (webhook_subscription_status in ('unknown', 'subscribed', 'unsubscribed', 'error'));

create index whatsapp_integration_health_check_idx
on public.whatsapp_integration_health (last_check_attempted_at desc);

create trigger set_updated_at
before update on public.whatsapp_integration_health
for each row execute function public.moddatetime('updated_at');

create index messages_whatsapp_account_activity_idx
on public.messages (organization_id, organization_address, direction, timestamp desc)
where service = 'whatsapp' and direction in ('incoming', 'outgoing');

create index logs_whatsapp_account_recent_idx
on public.logs (organization_id, organization_address, created_at desc)
where service = 'whatsapp' and level = 'error';
