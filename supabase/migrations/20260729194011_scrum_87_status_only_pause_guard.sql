drop trigger if exists "pause_conversation_on_human_message" on "public"."messages";

CREATE TRIGGER pause_conversation_on_human_message AFTER INSERT ON public.messages FOR EACH ROW WHEN (((new.direction = 'outgoing'::public.direction) AND (new.service <> 'local'::public.service) AND (new.content <> '{}'::jsonb) AND (new."timestamp" <= now()) AND (new."timestamp" >= (now() - '00:00:10'::interval)))) EXECUTE FUNCTION public.pause_conversation_on_human_message();
