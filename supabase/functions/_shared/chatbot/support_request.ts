import { z } from "zod";
import { conversationLifecycleEnabled } from "./conversation_lifecycle.ts";

export const supportRequestSchema = z.object({
  id: z.uuid(),
  status: z.enum(["waiting", "handling", "resolved", "released"]),
  target: z.union([
    z.object({ agent_id: z.uuid() }).strict(),
    z.object({ routing_queue_id: z.uuid() }).strict(),
  ]),
  source_wamid: z.string().startsWith("wamid."),
  requested_at: z.string().datetime({ offset: true }),
  reason: z.string().max(4096),
  handled_by_agent_id: z.uuid().optional(),
}).strict();

export function explicitTakeoverEnabled(organizationId: string): boolean {
  const tenants = (Deno.env.get("NODE_EXPLICIT_TAKEOVER_ORGANIZATIONS") ?? "")
    .split(",");
  return conversationLifecycleEnabled(organizationId) &&
    Deno.env.get("NODE_EXPLICIT_TAKEOVER_ENABLED") === "true" &&
    (tenants.includes("*") || tenants.includes(organizationId));
}
