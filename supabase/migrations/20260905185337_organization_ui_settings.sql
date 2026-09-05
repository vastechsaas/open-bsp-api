create table "public"."organization_ui_settings" (
  "organization_id" uuid not null,
  "chat_bubble_theme" text not null default 'orange'::text,
  "updated_at" timestamp with time zone not null default now(),
  "updated_by_user_id" uuid,
  "updated_by_scope" text not null default 'system'::text
);

alter table "public"."organization_ui_settings" enable row level security;

create unique index organization_ui_settings_pkey
on public.organization_ui_settings using btree (organization_id);

alter table "public"."organization_ui_settings"
add constraint "organization_ui_settings_pkey"
primary key using index "organization_ui_settings_pkey";

alter table "public"."organization_ui_settings"
add constraint "organization_ui_settings_organization_fkey"
foreign key (organization_id) references public.organizations(id) on delete cascade;

alter table "public"."organization_ui_settings"
add constraint "organization_ui_settings_scope_check"
check (updated_by_scope = any (array['system'::text, 'organization'::text]));

alter table "public"."organization_ui_settings"
add constraint "organization_ui_settings_theme_check"
check (chat_bubble_theme = any (array['orange'::text, 'green'::text, 'blue'::text, 'purple'::text, 'teal'::text]));

alter table "public"."organization_ui_settings"
add constraint "organization_ui_settings_updated_by_user_fkey"
foreign key (updated_by_user_id) references auth.users(id) on delete set null;

insert into public.organization_ui_settings (organization_id)
select id from public.organizations
on conflict (organization_id) do nothing;

set check_function_bodies = off;

create or replace function public.get_organization_ui_settings(p_organization_id uuid)
returns public.organization_ui_settings
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  settings public.organization_ui_settings;
begin
  if public.get_request_organization_role(p_organization_id) is null then
    raise exception using
      errcode = '42501',
      message = 'accepted organization membership required to read appearance settings';
  end if;

  select current_settings.* into settings
  from public.organization_ui_settings current_settings
  where current_settings.organization_id = p_organization_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'appearance settings not found';
  end if;

  return settings;
end;
$function$;

create or replace function public.initialize_organization_ui_settings()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  insert into public.organization_ui_settings (organization_id)
  values (new.id)
  on conflict (organization_id) do nothing;

  return new;
end;
$function$;

create or replace function public.update_organization_chat_bubble_theme(
  p_organization_id uuid,
  p_theme text
)
returns public.organization_ui_settings
language plpgsql
security definer
set search_path to ''
as $function$
declare
  request_role public.role;
  updated_settings public.organization_ui_settings;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null or request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage appearance settings';
  end if;

  if p_theme is null or p_theme not in ('orange', 'green', 'blue', 'purple', 'teal') then
    raise exception using errcode = '22023', message = 'invalid chat bubble theme';
  end if;

  update public.organization_ui_settings settings
  set chat_bubble_theme = p_theme,
      updated_at = now(),
      updated_by_user_id = auth.uid(),
      updated_by_scope = 'organization'
  where settings.organization_id = p_organization_id
  returning * into updated_settings;

  if not found then
    raise exception using errcode = 'P0002', message = 'appearance settings not found';
  end if;

  return updated_settings;
end;
$function$;

revoke all on table public.organization_ui_settings from anon, authenticated;
grant all on table public.organization_ui_settings to service_role;

revoke execute on function public.initialize_organization_ui_settings() from public;
revoke execute on function public.initialize_organization_ui_settings() from anon;
revoke execute on function public.initialize_organization_ui_settings() from authenticated;
revoke execute on function public.get_organization_ui_settings(uuid) from public;
revoke execute on function public.update_organization_chat_bubble_theme(uuid, text) from public;

grant execute on function public.get_organization_ui_settings(uuid) to authenticated;
grant execute on function public.update_organization_chat_bubble_theme(uuid, text) to authenticated;

create trigger initialize_organization_ui_settings
after insert on public.organizations
for each row execute function public.initialize_organization_ui_settings();
