import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import { createApiClient, createUnsecureClient } from "../_shared/supabase.ts";

const schema = z.object({
  phone_number_id: z.string().regex(/^\d+$/),
  recipient: z.string().regex(/^\d+$/),
  source_wamid: z.string().startsWith("wamid."),
  node_conversation_id: z.string().regex(/^\d+$/),
  target: z.union([
    z.object({ agent_id: z.uuid() }).strict(),
    z.object({ routing_queue_id: z.uuid() }).strict(),
  ]),
  chatbot: z.object({ key: z.string(), name: z.string() }).strict(),
}).strict();

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return Response.json({ message: "Method Not Allowed" }, { status: 405 });
  }
  const token = request.headers.get("Authorization");
  if (!token?.startsWith("Bearer ")) {
    return Response.json({ message: "Missing API key" }, { status: 401 });
  }
  const { data: key, error: authError } = await createApiClient(request).from(
    "api_keys",
  )
    .select("organization_id").eq("key", token.slice(7)).maybeSingle();
  if (authError || !key) {
    return Response.json({ message: "Invalid API key" }, { status: 401 });
  }
  try {
    const eventId = z.uuid().parse(request.headers.get("X-OpenBSP-Event-ID"));
    const payload = schema.parse(await request.json());
    const client = createUnsecureClient();
    const { data: address, error: addressError } = await client.from(
      "organizations_addresses",
    )
      .select("address").eq("organization_id", key.organization_id).eq(
        "service",
        "whatsapp",
      )
      .eq("address", payload.phone_number_id).eq("status", "connected")
      .maybeSingle();
    if (addressError) {
      return Response.json({ message: "Number lookup failed" }, {
        status: 503,
      });
    }
    if (!address) {
      return Response.json({
        message: "Number is not connected to this tenant",
      }, { status: 409 });
    }
    const { data, error } = await client.rpc("record_node_chatbot_handoff", {
      p_organization_id: key.organization_id,
      p_organization_address: address.address,
      p_recipient: payload.recipient,
      p_source_wamid: payload.source_wamid,
      p_node_conversation_id: payload.node_conversation_id,
      p_event_id: eventId,
      p_agent_id: "agent_id" in payload.target
        ? payload.target.agent_id
        : undefined,
      p_routing_queue_id: "routing_queue_id" in payload.target
        ? payload.target.routing_queue_id
        : undefined,
    });
    if (error) {
      return Response.json({
        message: error.code === "40001"
          ? "Customer message has not arrived yet"
          : "Handoff failed",
      }, {
        status: error.code === "40001"
          ? 503
          : error.code === "23514"
          ? 409
          : error.code === "42501"
          ? 403
          : 500,
      });
    }
    return Response.json({ conversation_id: data });
  } catch (error) {
    return Response.json({
      message: error instanceof z.ZodError
        ? "Invalid handoff payload"
        : "Handoff processing failed",
    }, { status: error instanceof z.ZodError ? 422 : 500 });
  }
});
