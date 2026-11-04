import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database } from "../_shared/supabase.ts";
import {
  campaignReplyPreview,
  signCampaignPreviews,
} from "./campaign_reply_context.ts";

const PAGE_SIZE = 30;
const timestamp = z.string().datetime({ offset: true });
const cursorSchema = z.object({
  timestamp,
  id: z.string().uuid(),
  source: z.enum(["message", "campaign"]),
}).strict();
export const campaignConversationHistoryRequest = z.object({
  organization_id: z.string().uuid(),
  conversation_id: z.string().uuid(),
  cursor: cursorSchema.optional(),
}).strict();

type Cursor = z.infer<typeof cursorSchema>;

function compareText(a: string, b: string) {
  return a === b ? 0 : a < b ? -1 : 1;
}

export function compareHistoryEntries(a: Cursor, b: Cursor) {
  return Date.parse(a.timestamp) - Date.parse(b.timestamp) ||
    compareText(
      (a.timestamp.match(/\.(\d+)/)?.[1] ?? "").padEnd(6, "0"),
      (b.timestamp.match(/\.(\d+)/)?.[1] ?? "").padEnd(6, "0"),
    ) || compareText(a.id, b.id) || compareText(a.source, b.source);
}

export function olderTimelineFilter(
  column: "timestamp" | "updated_at",
  cursor: Cursor,
  source: Cursor["source"],
) {
  // At the same timestamp and UUID, campaign sorts before message.
  const op = source < cursor.source ? "lte" : "lt";
  return `${column}.lt.${cursor.timestamp},and(${column}.eq.${cursor.timestamp},id.${op}.${cursor.id})`;
}

export async function readCampaignConversationHistory(
  user: SupabaseClient<Database>,
  service: SupabaseClient<Database>,
  input: z.infer<typeof campaignConversationHistoryRequest>,
) {
  const { organization_id, conversation_id, cursor } = input;
  const { data: conversation } = await user.from("conversations")
    .select("id,contact_address,organization_address")
    .eq("organization_id", organization_id).eq("id", conversation_id)
    .eq("service", "whatsapp").is("group_address", null)
    .maybeSingle().throwOnError();
  if (!conversation) return { accessible: false as const };

  const cutoff = new Date().toISOString();
  const chat = user.from("messages").select("*")
    .eq("organization_id", organization_id)
    .eq("conversation_id", conversation_id).lte("timestamp", cutoff)
    .order("timestamp", { ascending: false }).order("id", { ascending: false })
    .limit(PAGE_SIZE + 1);
  if (cursor) chat.or(olderTimelineFilter("timestamp", cursor, "message"));
  const recipient = conversation.contact_address?.replace(/^\+/, "");
  const inbound = recipient && /^\d+$/.test(recipient)
    ? user.from("messages").select("id").eq("organization_id", organization_id)
      .eq("conversation_id", conversation_id).eq("direction", "incoming")
      .eq("service", "whatsapp").limit(1).throwOnError()
    : null;
  const [{ data: messages }, firstReply] = await Promise.all([
    chat.throwOnError(),
    inbound,
  ]);

  const campaignRows = async () => {
    if (!recipient || !firstReply?.data?.length) return [];
    // An accepted delivery's updated_at records when acceptance became known,
    // not when the audience was queued. Delivery/read receipts are separate.
    const query = service.from("campaign_deliveries")
      .select(
        "id,updated_at,external_id,contact_address,name,variables,campaign:campaigns!campaign_deliveries_campaign_fkey!inner(name,organization_address,template,template_variable_mapping,carousel_media)",
      )
      .eq("organization_id", organization_id).eq("status", "accepted")
      .eq("campaign.organization_address", conversation.organization_address)
      .in("contact_address", [recipient, `+${recipient}`])
      .not("external_id", "is", null).lte("updated_at", cutoff)
      .order("updated_at", { ascending: false }).order("id", {
        ascending: false,
      })
      .limit(PAGE_SIZE + 1);
    if (cursor) query.or(olderTimelineFilter("updated_at", cursor, "campaign"));
    const { data } = await query.throwOnError();
    return data;
  };
  const deliveries = await campaignRows();
  const sorted = [
    ...messages.map((message) => ({
      source: "message" as const,
      id: message.id,
      timestamp: message.timestamp,
      message,
    })),
    ...deliveries.map((delivery) => ({
      source: "campaign" as const,
      id: delivery.id,
      timestamp: delivery.updated_at,
      delivery,
    })),
  ].sort((a, b) => compareHistoryEntries(b, a));
  const page = sorted.slice(0, PAGE_SIZE);
  const last = page.at(-1);
  const next_cursor = sorted.length > PAGE_SIZE && last
    ? { id: last.id, timestamp: last.timestamp, source: last.source }
    : undefined;
  const campaignPage = page.flatMap((entry) =>
    entry.source === "campaign" && entry.delivery.external_id
      ? [{
        ...entry,
        external_id: entry.delivery.external_id,
      }]
      : []
  );
  // Some older integrations already persisted outbound history. Prefer the
  // real message, even when it isn't on this page.
  const externalIds = campaignPage.map((entry) => entry.external_id);
  const existing = externalIds.length
    ? (await user.from("messages").select("external_id")
      .eq("organization_id", organization_id).eq(
        "conversation_id",
        conversation_id,
      )
      .eq("direction", "outgoing").in("external_id", externalIds)
      .throwOnError()).data
    : [];
  const duplicateIds = new Set(existing.map((row) => row.external_id));
  return {
    accessible: true as const,
    messages: page.flatMap((entry) =>
      entry.source === "message" ? [entry.message] : []
    ),
    campaigns: await signCampaignPreviews(
      service,
      campaignPage.flatMap(({ id, timestamp, external_id, delivery }) =>
        duplicateIds.has(external_id) ? [] : [{
          id,
          timestamp,
          external_id,
          ...campaignReplyPreview(delivery.campaign, delivery, organization_id),
        }]
      ),
    ),
    next_cursor,
  };
}
