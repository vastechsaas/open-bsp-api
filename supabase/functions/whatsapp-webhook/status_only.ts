import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../_shared/supabase.ts";

type StatusUpdate = {
  externalId: string;
  number: string;
  customer: string;
  status: Record<string, Json>;
};
const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

function knownContacts(value: unknown): boolean {
  const text = (item: unknown) =>
    item === undefined || item === null || typeof item === "string";
  return value === undefined ||
    (Array.isArray(value) &&
      value.every((contact) =>
        record(contact) && Object.keys(contact).every((key) =>
          ["wa_id", "user_id", "profile"].includes(key)
        ) &&
        text(contact.wa_id) && text(contact.user_id) &&
        (contact.profile === undefined ||
          (record(contact.profile) &&
            Object.keys(contact.profile).every((key) =>
              key === "name"
            ) && text(contact.profile.name)))
      ));
}

export function parseStatusOnly(payload: unknown): StatusUpdate[] | undefined {
  if (
    !record(payload) || payload.object !== "whatsapp_business_account" ||
    !Array.isArray(payload.entry) || !payload.entry.length
  ) return;
  const result: StatusUpdate[] = [];
  for (const entry of payload.entry) {
    if (
      !record(entry) || !Array.isArray(entry.changes) || !entry.changes.length
    ) return;
    for (const change of entry.changes) {
      if (
        !record(change) || change.field !== "messages" || !record(change.value)
      ) return;
      const value = change.value;
      if (
        Object.keys(value).some((key) =>
          !["messaging_product", "metadata", "statuses", "contacts"].includes(
            key,
          )
        ) ||
        !knownContacts(value.contacts) || !record(value.metadata) ||
        typeof value.metadata.phone_number_id !== "string" ||
        !Array.isArray(value.statuses) || !value.statuses.length
      ) return;
      for (const status of value.statuses) {
        if (
          !record(status) || typeof status.id !== "string" ||
          !status.id.startsWith("wamid.") ||
          typeof status.recipient_id !== "string" ||
          !/^\d+$/.test(status.recipient_id) ||
          !["sent", "delivered", "read"].includes(String(status.status)) ||
          typeof status.timestamp !== "string" ||
          !/^\d+$/.test(status.timestamp)
        ) return;
        const date = new Date(Number(status.timestamp) * 1000);
        if (!Number.isFinite(date.getTime())) return;
        result.push({
          externalId: status.id,
          number: value.metadata.phone_number_id,
          customer: status.recipient_id,
          status: { [String(status.status)]: date.toISOString() },
        });
        if (result.length > 100) return;
      }
    }
  }
  return result.length ? result : undefined;
}

// Called only after both Meta signature and the existing tenant API credential
// are verified. UPDATE (never UPSERT) cannot invent a message or move episodes.
export async function processStatusOnly(
  payload: unknown,
  organization: string,
  allowedNumbers: Set<string>,
  client: SupabaseClient<Database>,
): Promise<Response> {
  const updates = parseStatusOnly(payload);
  if (!updates) {
    return new Response("Invalid status-only webhook", { status: 400 });
  }
  if (updates.some((row) => !allowedNumbers.has(row.number))) {
    return new Response("Status tenant mismatch", { status: 403 });
  }
  const { data: messages, error } = await client.from("messages")
    .select(
      "id,external_id,organization_address,contact_address,direction,service",
    )
    .eq("organization_id", organization).in("external_id", [
      ...new Set(updates.map((row) => row.externalId)),
    ]);
  if (error) return new Response("Status lookup unavailable", { status: 503 });
  const matches = updates.map((update) =>
    messages?.find((message) =>
      message.external_id === update.externalId &&
      message.organization_address === update.number &&
      message.contact_address === update.customer &&
      message.direction === "outgoing" && message.service === "whatsapp"
    )
  );
  if (matches.some((message) => !message)) {
    return new Response("Original message pending", { status: 503 });
  }
  for (const [index, update] of updates.entries()) {
    const { data, error } = await client.from("messages").update({
      status: update.status,
    })
      .eq("organization_id", organization).eq("id", matches[index]!.id).select(
        "id",
      ).maybeSingle();
    if (error || !data) {
      return new Response("Status update pending", { status: 503 });
    }
  }
  return new Response();
}
