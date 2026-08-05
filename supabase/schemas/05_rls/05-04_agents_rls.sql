alter table public.agents enable row level security;

create policy "members can read themselves"
on public.agents
for select
to authenticated
using (
  user_id = auth.uid()
);

create policy "members can update themselves"
on public.agents
for update
to authenticated
using (
  user_id = auth.uid()
)
with check (
  user_id = auth.uid()
  and public.member_self_update_rules(id, user_id, organization_id, ai, extra)
);

create policy "members can delete themselves"
on public.agents
for delete
to authenticated
using (
  user_id = auth.uid()
);

create policy "members can read their orgs agents"
on public.agents
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "admins can manage their orgs ai agents"
on public.agents
for all
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and user_id is null
  and ai = true
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
);

create policy "admins can create their orgs ai agents"
on public.agents
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and ai = true
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
);

create policy "owners can send invitations"
on public.agents
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('owner')
  )
  and ai = false
  and extra->'invitation'->>'status' = 'pending'
  and extra->'invitation'->>'email' is not null
);

create policy "admins and supervisors can send member or agent invitations"
on public.agents
for insert
to authenticated
with check (
  organization_id in (
    select public.get_authorized_orgs('supervisor')
  )
  and user_id is null
  and ai = false
  and extra->>'role' in ('member', 'agent')
  and extra->'invitation'->>'status' = 'pending'
  and extra->'invitation'->>'email' is not null
);

create policy "admins and supervisors can update members or agents"
on public.agents
for update
to authenticated
using (
  organization_id in (
    select public.get_authorized_orgs('supervisor')
  )
  and ai = false
  and extra->>'role' in ('member', 'agent')
)
with check (
  public.member_update_by_supervisor_rules(
    id,
    user_id,
    organization_id,
    ai,
    extra
  )
);

create policy "admins and supervisors can delete members or agents"
on public.agents
for delete
to authenticated
using (
  organization_id in (
    select public.get_authorized_orgs('supervisor')
  )
  and ai = false
  and extra->>'role' in ('member', 'agent')
);

create policy "owners can update their orgs agents"
on public.agents
for update
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('owner')
  )
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
)
with check (
  organization_id in (
    select public.get_authorized_orgs('owner')
  )
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
  and
  public.agent_update_by_owner_rules(id, user_id, organization_id, ai, extra)
);

create policy "owners can delete their orgs agents"
on public.agents
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('owner')
  )
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
);
