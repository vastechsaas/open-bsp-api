  create table "public"."user_notifications" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "recipient_agent_id" uuid not null,
    "actor_agent_id" uuid,
    "conversation_id" uuid,
    "notification_type" text not null,
    "source_event_key" text not null,
    "payload" jsonb not null default '{}'::jsonb,
    "created_at" timestamp with time zone not null default now(),
    "read_at" timestamp with time zone,
    "resolved_at" timestamp with time zone
      );


alter table "public"."user_notifications" enable row level security;

CREATE UNIQUE INDEX conversations_organization_id_id_key ON public.conversations USING btree (organization_id, id);

CREATE INDEX user_notifications_conversation_idx ON public.user_notifications USING btree (organization_id, conversation_id) WHERE (conversation_id IS NOT NULL);

CREATE UNIQUE INDEX user_notifications_pkey ON public.user_notifications USING btree (id);

CREATE UNIQUE INDEX user_notifications_recipient_source_key ON public.user_notifications USING btree (organization_id, recipient_agent_id, source_event_key);

CREATE INDEX user_notifications_recipient_time_idx ON public.user_notifications USING btree (organization_id, recipient_agent_id, created_at DESC, id DESC);

CREATE INDEX user_notifications_unread_idx ON public.user_notifications USING btree (organization_id, recipient_agent_id, created_at DESC, id DESC) WHERE ((read_at IS NULL) AND (resolved_at IS NULL));

alter table "public"."user_notifications" add constraint "user_notifications_pkey" PRIMARY KEY using index "user_notifications_pkey";

alter table "public"."conversations" add constraint "conversations_organization_id_id_key" UNIQUE using index "conversations_organization_id_id_key";

alter table "public"."user_notifications" add constraint "user_notifications_actor_agent_fkey" FOREIGN KEY (organization_id, actor_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (actor_agent_id) not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_actor_agent_fkey";

alter table "public"."user_notifications" add constraint "user_notifications_conversation_fkey" FOREIGN KEY (organization_id, conversation_id) REFERENCES public.conversations(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_conversation_fkey";

alter table "public"."user_notifications" add constraint "user_notifications_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_organization_id_fkey";

alter table "public"."user_notifications" add constraint "user_notifications_payload_check" CHECK ((jsonb_typeof(payload) = 'object'::text)) not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_payload_check";

alter table "public"."user_notifications" add constraint "user_notifications_read_at_check" CHECK (((read_at IS NULL) OR (read_at >= created_at))) not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_read_at_check";

alter table "public"."user_notifications" add constraint "user_notifications_recipient_agent_fkey" FOREIGN KEY (organization_id, recipient_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_recipient_agent_fkey";

alter table "public"."user_notifications" add constraint "user_notifications_recipient_source_key" UNIQUE using index "user_notifications_recipient_source_key";

alter table "public"."user_notifications" add constraint "user_notifications_resolved_at_check" CHECK (((resolved_at IS NULL) OR (resolved_at >= created_at))) not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_resolved_at_check";

alter table "public"."user_notifications" add constraint "user_notifications_source_event_key_check" CHECK ((length(btrim(source_event_key)) > 0)) not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_source_event_key_check";

alter table "public"."user_notifications" add constraint "user_notifications_type_check" CHECK ((notification_type = ANY (ARRAY['conversation_assigned'::text, 'conversation_transferred_to_agent'::text, 'conversation_transferred_to_queue'::text, 'private_note_mention'::text]))) not valid;

alter table "public"."user_notifications" validate constraint "user_notifications_type_check";

grant select on table public.user_notifications to authenticated;

grant all on table public.user_notifications to service_role;

  create policy "accepted humans can read their own notifications"
  on "public"."user_notifications"
  as permissive
  for select
  to authenticated
using (((public.get_request_organization_role(organization_id) IS NOT NULL) AND (recipient_agent_id = public.get_current_human_agent_id(organization_id))));


