set check_function_bodies = off;

create or replace function public.member_update_by_supervisor_rules(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid,
  p_ai boolean,
  p_extra jsonb
) returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
      and ai = false
      and p_ai = false
      and extra->>'role' = 'member'
      and extra is not distinct from p_extra
  );
end;
$function$;

create policy "supervisors can delete members"
on public.agents
as permissive
for delete
to authenticated
using (
  organization_id in (
    select public.get_authorized_orgs('supervisor'::public.role)
  )
  and ai = false
  and extra->>'role' = 'member'
);

create policy "supervisors can send member invitations"
on public.agents
as permissive
for insert
to authenticated
with check (
  organization_id in (
    select public.get_authorized_orgs('supervisor'::public.role)
  )
  and user_id is null
  and ai = false
  and extra->>'role' = 'member'
  and extra->'invitation'->>'status' = 'pending'
  and extra->'invitation'->>'email' is not null
);

create policy "supervisors can update members"
on public.agents
as permissive
for update
to authenticated
using (
  organization_id in (
    select public.get_authorized_orgs('supervisor'::public.role)
  )
  and ai = false
  and extra->>'role' = 'member'
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
