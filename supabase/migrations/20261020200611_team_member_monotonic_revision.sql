CREATE OR REPLACE FUNCTION public.set_team_member_revision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  new.updated_at:=greatest(clock_timestamp(),old.updated_at+interval '1 microsecond');
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_last_owner_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  owner_count int;
begin
  -- Skip check if org is being deleted (cascade delete)
  perform public.lock_organization_team(old.organization_id);
  if not exists (select 1 from public.organizations where id=old.organization_id) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if old.extra->>'role' = 'owner'
    and coalesce(old.extra->'invitation'->>'status','accepted')='accepted' then
    select count(*) into owner_count
    from public.agents
    where organization_id = old.organization_id
      and extra->>'role' = 'owner'
      and (
        extra->>'invitation' is null
        or extra->'invitation'->>'status' = 'accepted'
      )
      and id <> old.id;

    if owner_count = 0 then
      raise exception 'Cannot delete the last owner of an organization';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$
;

CREATE TRIGGER zz_set_team_member_revision BEFORE UPDATE ON public.agents FOR EACH ROW WHEN ((NOT new.ai)) EXECUTE FUNCTION public.set_team_member_revision();



revoke all on function public.set_team_member_revision() from public, anon, authenticated;
