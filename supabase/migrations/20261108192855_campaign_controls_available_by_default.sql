alter table "public"."campaign_dispatch_settings" alter column "enabled" set default true;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.initialize_campaign_dispatch_settings()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.campaign_dispatch_settings (organization_id, enabled)
  values (new.id, true)
  on conflict (organization_id) do nothing;
  return new;
end;
$function$
;

CREATE TRIGGER initialize_campaign_dispatch_settings AFTER INSERT ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.initialize_campaign_dispatch_settings();

-- Trigger-only function is not a tenant RPC.
revoke all on function public.initialize_campaign_dispatch_settings() from public, anon, authenticated;
grant execute on function public.initialize_campaign_dispatch_settings() to service_role;

-- Existing organizations receive availability without changing policy enforcement,
-- limits, campaign snapshots, accounting, or already-selected transports.
insert into public.campaign_dispatch_settings (organization_id, enabled)
select id, true from public.organizations
on conflict (organization_id) do update set enabled = true
where not campaign_dispatch_settings.enabled;


