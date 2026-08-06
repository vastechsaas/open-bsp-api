alter table public.message_mentions enable row level security;

grant select on table public.message_mentions to authenticated;
grant all on table public.message_mentions to service_role;

create policy "members can read their orgs message mentions"
on public.message_mentions
for select
to authenticated
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "agents can read their own message mentions"
on public.message_mentions
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
  and mentioned_agent_id = public.get_current_human_agent_id(organization_id)
);
