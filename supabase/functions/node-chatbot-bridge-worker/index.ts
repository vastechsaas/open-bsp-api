import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createUnsecureClient } from "../_shared/supabase.ts";
import { processNodeBridgeOperation } from "../_shared/chatbot/node_bridge_processor.ts";

Deno.serve(async (request) => {
  const serviceKey = Deno.env.get("EDGE_FUNCTIONS_TOKEN") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (
    request.method !== "POST" || !serviceKey ||
    request.headers.get("Authorization") !== `Bearer ${serviceKey}`
  ) {
    return new Response("Unauthorized", { status: 401 });
  }
  if (Deno.env.get("NODE_CHATBOT_BRIDGE_ENABLED") !== "true") {
    return Response.json({ disabled: true });
  }
  const { data, error } = await createUnsecureClient().from(
    "chatbot_node_operations",
  ).select("request_id")
    .in("status", ["pending", "in_flight", "reconciling", "retry_wait"])
    .or(
      `next_attempt_at.is.null,next_attempt_at.lte.${new Date().toISOString()}`,
    )
    .order("created_at").limit(10);
  if (error) {
    return Response.json({ message: "Unable to load bridge work" }, {
      status: 503,
    });
  }
  const results = [];
  for (const operation of data ?? []) {
    try {
      await processNodeBridgeOperation(operation.request_id);
      results.push({ request_id: operation.request_id, processed: true });
    } catch {
      results.push({ request_id: operation.request_id, processed: false });
    }
  }
  return Response.json({ results });
});
