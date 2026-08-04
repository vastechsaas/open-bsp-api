drop policy "members can update themselves" on public.agents;
drop policy "owners can update their orgs agents" on public.agents;

create policy "members can update themselves"
on public.agents
as permissive
for update
to authenticated
using (
  user_id = auth.uid()
)
with check (
  user_id = auth.uid()
  and public.member_self_update_rules(id, user_id, organization_id, ai, extra)
);

create policy "owners can update their orgs agents"
on public.agents
as permissive
for update
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('owner'::public.role)
  )
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
)
with check (
  organization_id in (
    select public.get_authorized_orgs('owner'::public.role)
  )
  and coalesce(extra->>'kind', '') <> 'chatbot_runtime'
  and public.agent_update_by_owner_rules(id, user_id, organization_id, ai, extra)
);
