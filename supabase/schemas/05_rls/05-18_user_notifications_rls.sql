alter table public.user_notifications enable row level security;

grant select on table public.user_notifications to authenticated;
grant all on table public.user_notifications to service_role;

create policy "accepted humans can read their own notifications"
on public.user_notifications
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) is not null
  and recipient_agent_id = public.get_current_human_agent_id(organization_id)
);
