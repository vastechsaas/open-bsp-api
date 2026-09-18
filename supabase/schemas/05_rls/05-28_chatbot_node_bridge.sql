create policy tenant_bridge_read on public.chatbot_node_bridges for select to authenticated
  using (organization_id in (select public.get_authorized_orgs('agent')));
create policy tenant_bridge_conversation_read on public.chatbot_node_conversations for select to authenticated
  using (organization_id in (select public.get_authorized_orgs('agent')));
