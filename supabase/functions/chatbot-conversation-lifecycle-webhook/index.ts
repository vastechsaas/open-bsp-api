import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import { createApiClient, createUnsecureClient } from "../_shared/supabase.ts";
import { conversationLifecycleEnabled } from "../_shared/chatbot/conversation_lifecycle.ts";

const schema = z.object({
  phone_number_id: z.string().regex(/^\d+$/),
  recipient: z.string().regex(/^\d+$/),
  node_conversation_id: z.string().regex(/^\d+$/),
  revision: z.string().regex(/^\d+$/),
  state: z.enum(["human_owned", "closed", "bot_ready", "bot_active"]),
  last_inbound_wamid: z.string().startsWith("wamid."),
  source_wamid: z.string().startsWith("wamid.").optional(),
  request_id: z.uuid().optional(),
  chatbot: z.object({ key: z.string(), name: z.string() }).strict(),
}).strict();

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }
  const token = request.headers.get("Authorization");
  if (!token?.startsWith("Bearer ")) {
    return new Response("Unauthorized", { status: 401 });
  }
  const { data: key } = await createApiClient(request).from("api_keys").select(
    "organization_id",
  )
    .eq("key", token.slice(7)).maybeSingle();
  if (!key) return new Response("Unauthorized", { status: 401 });
  if (!conversationLifecycleEnabled(key.organization_id)) {
    return new Response("Lifecycle feature is disabled", { status: 503 });
  }
  try {
    z.uuid().parse(request.headers.get("X-OpenBSP-Event-ID"));
    const payload = schema.parse(await request.json());
    const { data: address } = await createUnsecureClient().from(
      "organizations_addresses",
    ).select("address")
      .eq("organization_id", key.organization_id).eq(
        "address",
        payload.phone_number_id,
      ).eq("service", "whatsapp").eq("status", "connected").maybeSingle();
    if (!address) {
      return new Response("Number is not connected to this tenant", {
        status: 409,
      });
    }
    const { data, error } = await createUnsecureClient().rpc(
      "apply_node_conversation_lifecycle",
      {
        p_organization_id: key.organization_id,
        p_address: address.address,
        p_node_conversation_id: payload.node_conversation_id,
        p_recipient: payload.recipient,
        p_revision: payload.revision,
        p_state: payload.state,
        p_last_inbound_wamid: payload.last_inbound_wamid,
        p_source_wamid: payload.source_wamid,
        p_request_id: payload.request_id,
      },
    );
    if (error) {
      return Response.json({
        message: error.code === "40001"
          ? "Customer message has not arrived yet"
          : "Lifecycle update failed",
      }, {
        status: error.code === "40001"
          ? 503
          : error.code === "42501"
          ? 403
          : error.code === "23514"
          ? 409
          : 500,
      });
    }
    return Response.json({ conversation_id: data });
  } catch (error) {
    return Response.json({
      message: error instanceof z.ZodError
        ? "Invalid lifecycle payload"
        : "Lifecycle processing failed",
    }, { status: error instanceof z.ZodError ? 422 : 500 });
  }
});
