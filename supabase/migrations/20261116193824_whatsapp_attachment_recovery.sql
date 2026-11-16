-- Generated from staging schema; only attachment recovery changes retained.

set check_function_bodies = off;

create table "public"."whatsapp_attachment_recovery_jobs" (
    "message_id" uuid not null,
    "media_id" text not null,
    "state" text not null default 'pending'::text,
    "next_attempt_at" timestamp with time zone not null default now(),
    "automatic_attempts" integer not null default 0,
    "manual_attempts" integer not null default 0,
    "manual" boolean not null default false,
    "manual_requested_at" timestamp with time zone,
    "lease_token" uuid,
    "lease_until" timestamp with time zone
      );

alter table "public"."whatsapp_attachment_recovery_jobs" enable row level security;

CREATE INDEX whatsapp_attachment_recovery_jobs_due_idx ON public.whatsapp_attachment_recovery_jobs USING btree (next_attempt_at, message_id) WHERE (state = 'pending'::text);

CREATE UNIQUE INDEX whatsapp_attachment_recovery_jobs_pkey ON public.whatsapp_attachment_recovery_jobs USING btree (message_id);

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_pkey" PRIMARY KEY using index "whatsapp_attachment_recovery_jobs_pkey";

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_automatic_attempts_check" CHECK (((automatic_attempts >= 0) AND (automatic_attempts <= 4))) not valid;

alter table "public"."whatsapp_attachment_recovery_jobs" validate constraint "whatsapp_attachment_recovery_jobs_automatic_attempts_check";

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_check" CHECK (((lease_token IS NULL) = (lease_until IS NULL))) not valid;

alter table "public"."whatsapp_attachment_recovery_jobs" validate constraint "whatsapp_attachment_recovery_jobs_check";

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_manual_attempts_check" CHECK (((manual_attempts >= 0) AND (manual_attempts <= 2))) not valid;

alter table "public"."whatsapp_attachment_recovery_jobs" validate constraint "whatsapp_attachment_recovery_jobs_manual_attempts_check";

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_media_id_check" CHECK ((media_id ~ '^[0-9]{1,40}$'::text)) not valid;

alter table "public"."whatsapp_attachment_recovery_jobs" validate constraint "whatsapp_attachment_recovery_jobs_media_id_check";

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_message_id_fkey" FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE not valid;

alter table "public"."whatsapp_attachment_recovery_jobs" validate constraint "whatsapp_attachment_recovery_jobs_message_id_fkey";

alter table "public"."whatsapp_attachment_recovery_jobs" add constraint "whatsapp_attachment_recovery_jobs_state_check" CHECK ((state = ANY (ARRAY['pending'::text, 'ready'::text, 'failed'::text, 'unavailable'::text, 'credentials'::text, 'storage'::text, 'too_large'::text, 'cancelled'::text]))) not valid;

alter table "public"."whatsapp_attachment_recovery_jobs" validate constraint "whatsapp_attachment_recovery_jobs_state_check";

CREATE OR REPLACE FUNCTION public.claim_whatsapp_attachment_recovery()
 RETURNS TABLE(message_id uuid, lease_token uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare stale record;
begin
  if not pg_try_advisory_xact_lock(824038171) then return; end if;
  for stale in
    select j.message_id, j.lease_token from public.whatsapp_attachment_recovery_jobs j
    where j.state = 'pending' and j.lease_until <= now() order by j.lease_until limit 5
    for update skip locked
  loop
    perform public.finish_whatsapp_attachment_recovery(stale.message_id,stale.lease_token,'temporary');
  end loop;
  -- Cap total parallel transfers across overlapping Edge invocations.
  if (select count(*) from public.whatsapp_attachment_recovery_jobs j where j.lease_until > now()) >= 2
  then return; end if;
  return query
    with due as (
      select j.message_id from public.whatsapp_attachment_recovery_jobs j
      where j.state = 'pending' and j.next_attempt_at <= now() and j.lease_token is null
      order by j.next_attempt_at, j.message_id limit 1 for update skip locked
    )
    update public.whatsapp_attachment_recovery_jobs j set lease_token = gen_random_uuid(),
      lease_until = now() + interval '120 seconds',
      automatic_attempts = j.automatic_attempts + case when j.manual then 0 else 1 end
    from due where j.message_id = due.message_id returning j.message_id, j.lease_token;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_whatsapp_attachment_recovery(p_message_id uuid, p_lease_token uuid, p_outcome text, p_path text DEFAULT NULL::text, p_size integer DEFAULT NULL::integer, p_retry_after integer DEFAULT 0)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  job public.whatsapp_attachment_recovery_jobs;
  message public.messages;
  outcome text := p_outcome;
  delay_seconds integer := least(86400, greatest(0, coalesce(p_retry_after,0)));
begin
  select * into job from public.whatsapp_attachment_recovery_jobs
  where message_id = p_message_id and state = 'pending' and lease_token = p_lease_token for update;
  if not found then return false; end if;
  if outcome = 'ready' and job.lease_until <= now() then return false; end if;

  if outcome is null or outcome not in ('ready','temporary','unavailable','credentials','storage','too_large','cancelled') then
    raise exception 'Invalid attachment recovery outcome';
  end if;
  select * into message from public.messages where id = p_message_id for update;
  if not found or message.status ? 'deleted' or message.content#>>'{file,uri}' is distinct from job.media_id then
    outcome := 'cancelled';
  elsif not public.is_organization_active(message.organization_id) then
    outcome := 'cancelled';
  elsif outcome <> 'cancelled' and not exists (
    select 1 from public.organizations_addresses a where a.organization_id = message.organization_id
    and a.address = message.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then
    outcome := 'credentials';
  end if;

  if outcome = 'ready' then
    if p_path is null or p_path !~ ('^organizations/' || message.organization_id || '/attachments/[a-zA-Z0-9_-]{43}$')
      or p_size is null or p_size < 1
      or not exists (select 1 from storage.objects where bucket_id = 'media' and name = p_path
        and metadata->>'size' = p_size::text)
    then raise exception 'Attachment storage object not verified'; end if;
    update public.messages set content = jsonb_build_object('attachment_recovery','ready',
      'file',jsonb_build_object('uri','internal://media/' || p_path, 'size',p_size)) where id = p_message_id;
  elsif outcome = 'temporary' and not job.manual and job.automatic_attempts < 4 then
    delay_seconds := greatest(case job.automatic_attempts when 1 then 30 when 2 then 120 else 600 end,
      delay_seconds);
    outcome := 'pending';
  else
    if outcome = 'temporary' then outcome := 'failed'; end if;
    if message.id is not null and not (message.status ? 'deleted')
      and message.content#>>'{file,uri}' = job.media_id then
      update public.messages set content = jsonb_build_object('attachment_recovery',outcome)
      where id = p_message_id;
    end if;
  end if;
  update public.whatsapp_attachment_recovery_jobs set state = outcome,
    next_attempt_at = now() + make_interval(secs => delay_seconds), lease_token = null, lease_until = null
    where message_id = p_message_id;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.persist_whatsapp_attachment_messages(p_messages jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare inserted integer;
begin
  if jsonb_typeof(p_messages) is distinct from 'array' then
    raise exception 'Invalid attachment message batch';
  end if;
  with new_messages as (
    insert into public.messages (
      organization_id, conversation_id, external_id, direction, service,
      organization_address, contact_address, group_address, content, timestamp
    )
    select v.organization_id, v.conversation_id, v.external_id, 'incoming', 'whatsapp',
      v.organization_address, v.contact_address, v.group_address,
      jsonb_set(v.content, '{attachment_recovery}', '"pending"'), v.timestamp
    from jsonb_populate_recordset(null::public.messages, p_messages) v
    where v.direction = 'incoming' and v.service = 'whatsapp'
      and v.external_id is not null and v.content->>'type' = 'file'
      and v.content#>>'{file,uri}' ~ '^[0-9]{1,40}$'
    on conflict (external_id) do nothing
    returning id, content
  )
  insert into public.whatsapp_attachment_recovery_jobs (message_id, media_id)
  select id, content#>>'{file,uri}' from new_messages;
  get diagnostics inserted = row_count;
  return inserted;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.preserve_whatsapp_attachment_recovery()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if old.service = 'whatsapp' and old.direction = 'incoming'
    and (old.content ? 'attachment_recovery' or old.content#>>'{file,uri}' like 'internal://media/%')
    and new.content#>>'{file,uri}' ~ '^[0-9]{1,40}$'
    and new.content ? 'file'
    and not (new.content ? 'attachment_recovery')
  then
    new.content := jsonb_set(new.content, '{file}', old.content->'file');
    if old.content ? 'attachment_recovery' then
      new.content := jsonb_set(new.content, '{attachment_recovery}', old.content->'attachment_recovery');
    end if;
    if new.status ? 'error' then
      new.status := (new.status - 'error') ||
        case when old.status ? 'error' then jsonb_build_object('error', old.status->'error') else '{}'::jsonb end;
    end if;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.retry_whatsapp_attachment_recovery(p_message_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare message public.messages; job public.whatsapp_attachment_recovery_jobs;
begin
  select * into message from public.messages where id = p_message_id;
  if not found or auth.uid() is null or not public.is_organization_active(message.organization_id)
    or not (message.organization_id in (select public.get_authorized_orgs('member'))
      or coalesce(public.agent_can_read_conversation(message.organization_id, message.conversation_id), false))
  then return 'not_found'; end if;
  select * into job from public.whatsapp_attachment_recovery_jobs where message_id = p_message_id for update;
  if not found then return 'not_found'; end if;
  -- Recheck current record after waiting for any running completion.
  select * into message from public.messages where id = p_message_id;
  if not found or message.status ? 'deleted' or (job.state <> 'ready' and
    message.content#>>'{file,uri}' is distinct from job.media_id)
  then return 'not_found'; end if;
  if job.state in ('pending','ready') then return job.state; end if;
  if job.state not in ('failed','credentials','storage') then return job.state; end if;
  if job.manual_attempts >= 2 then return 'limit'; end if;
  if job.next_attempt_at > now() then return 'rate_limited'; end if;
  if job.manual_requested_at > now() - interval '5 minutes' then return 'cooldown'; end if;
  update public.whatsapp_attachment_recovery_jobs set state='pending', manual=true,
    manual_attempts=manual_attempts+1, manual_requested_at=now(), next_attempt_at=now()
    where message_id = p_message_id;
  update public.messages set content=jsonb_build_object('attachment_recovery','pending') where id=p_message_id;
  return 'pending';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.wake_whatsapp_attachment_recovery()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base text; token text;
begin
  if not exists (select 1 from public.whatsapp_attachment_recovery_jobs j
    where j.state='pending' and j.next_attempt_at <= now() and (j.lease_until is null or j.lease_until <= now()))
  then return; end if;
  select decrypted_secret into base from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into token from vault.decrypted_secrets where name = 'edge_functions_token';
  if coalesce(base,'') = '' or coalesce(token,'') = '' then return; end if;
  perform net.http_post(url := rtrim(base,'/') || '/whatsapp-attachment-recovery',
    headers := jsonb_build_object('authorization','Bearer ' || token, 'content-type','application/json'),
    timeout_milliseconds := 110000);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.whatsapp_attachment_recovery_context(p_message_id uuid, p_lease_token uuid)
 RETURNS TABLE(media_id text, organization_id uuid, organization_address text, account_status text, access_token text, filename text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select j.media_id, m.organization_id, m.organization_address, a.status, a.extra->>'access_token', m.content#>>'{file,name}'
  from public.whatsapp_attachment_recovery_jobs j
  join public.messages m on m.id = j.message_id
  left join public.organizations_addresses a on a.organization_id = m.organization_id
    and a.address = m.organization_address and a.service = 'whatsapp'
  where j.message_id = p_message_id and j.lease_token = p_lease_token and j.lease_until > now()
    and m.service = 'whatsapp' and m.direction = 'incoming' and not (m.status ? 'deleted')
    and m.content#>>'{file,uri}' = j.media_id and public.is_organization_active(m.organization_id);
$function$
;

CREATE TRIGGER handle_recovered_attachment_media_preprocessing AFTER UPDATE ON public.messages FOR EACH ROW WHEN ((((new.content ->> 'attachment_recovery'::text) = 'ready'::text) AND ((old.content ->> 'attachment_recovery'::text) IS DISTINCT FROM 'ready'::text) AND (new.status ? 'pending'::text) AND (NOT (new.status ? 'preprocessed'::text)))) EXECUTE FUNCTION public.edge_function('/media-preprocessor', 'post');

CREATE TRIGGER preserve_whatsapp_attachment_recovery BEFORE UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.preserve_whatsapp_attachment_recovery();

revoke all on table public.whatsapp_attachment_recovery_jobs from public, anon, authenticated;

revoke all on function public.persist_whatsapp_attachment_messages(jsonb),
  public.preserve_whatsapp_attachment_recovery(),
  public.finish_whatsapp_attachment_recovery(uuid,uuid,text,text,integer,integer),
  public.claim_whatsapp_attachment_recovery(),
  public.whatsapp_attachment_recovery_context(uuid,uuid),
  public.retry_whatsapp_attachment_recovery(uuid),
  public.wake_whatsapp_attachment_recovery()
from public, anon, authenticated;
grant execute on function public.persist_whatsapp_attachment_messages(jsonb),
  public.finish_whatsapp_attachment_recovery(uuid,uuid,text,text,integer,integer),
  public.claim_whatsapp_attachment_recovery(),
  public.whatsapp_attachment_recovery_context(uuid,uuid)
to service_role;
grant execute on function public.retry_whatsapp_attachment_recovery(uuid) to authenticated;

-- pg_cron job definitions are data: carry this statement into the generated migration.
select cron.schedule('whatsapp-attachment-recovery', '10 seconds',
  'select public.wake_whatsapp_attachment_recovery();');
