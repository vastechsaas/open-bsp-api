import type { IntegrationEvent } from "./contracts.js";

export type Lane = "messages" | "statuses";
type Value = Record<string, unknown>;
const record = (value: unknown): value is Value =>
  value !== null && typeof value === "object" && !Array.isArray(value);

// Identity metadata accompanies Main's real receipts. It is not an inbound
// message. Unknown contact payloads still use the conservative message lane.
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

export function webhookValues(raw: string): Value[] | undefined {
  try {
    const body: unknown = JSON.parse(raw);
    if (
      !record(body) || body.object !== "whatsapp_business_account" ||
      !Array.isArray(body.entry) || !body.entry.length
    ) return;
    const values: Value[] = [];
    for (const entry of body.entry) {
      if (
        !record(entry) || !Array.isArray(entry.changes) || !entry.changes.length
      ) return;
      for (const change of entry.changes) {
        if (
          !record(change) || change.field !== "messages" ||
          !record(change.value)
        ) return;
        values.push(change.value);
      }
    }
    return values;
  } catch {
    return;
  }
}

export function eventLane(event: IntegrationEvent): Lane {
  if (event.event_type !== "whatsapp_webhook") return "messages";
  const values = webhookValues(event.payload.raw_body);
  if (!values?.length) return "messages";
  return values.every((value) => {
      if (
        Object.keys(value).some((key) =>
          !["messaging_product", "metadata", "statuses", "contacts"].includes(
            key,
          )
        )
      ) return false;
      return knownContacts(value.contacts) && record(value.metadata) &&
        typeof value.metadata.phone_number_id === "string" &&
        Array.isArray(value.statuses) && value.statuses.length > 0 &&
        value.statuses.every((status) =>
          record(status) && typeof status.id === "string" &&
          typeof status.recipient_id === "string" &&
          ["sent", "delivered", "read"].includes(String(status.status))
        );
    })
    ? "statuses"
    : "messages";
}

export type Reservation = { integration: string; keys: string[] };
export function eventReservation(event: IntegrationEvent): Reservation {
  const integration = event.integration_key;
  if (event.event_type !== "whatsapp_webhook") {
    return {
      integration,
      keys: [`${event.payload.phone_number_id}:${event.payload.recipient}`],
    };
  }
  const values = webhookValues(event.payload.raw_body);
  if (eventLane(event) === "statuses") {
    // Database status merging is atomic. Only repeats of the same status for
    // the same message need local ordering; receipts for different messages or
    // different status fields must not serialize an entire customer burst.
    const keys = (values ?? []).flatMap((value) => {
      const number =
        (value.metadata as { phone_number_id: string }).phone_number_id;
      return (value.statuses as Array<
        { id: string; recipient_id: string; status: string }
      >).map(
        (status) =>
          JSON.stringify([
            number,
            status.recipient_id,
            status.id,
            status.status,
          ]),
      );
    });
    return { integration, keys: [...new Set(keys)].sort() };
  }
  const keys: string[] = [];
  for (const value of values ?? []) {
    if (
      !record(value.metadata) ||
      typeof value.metadata.phone_number_id !== "string"
    ) return { integration, keys: [] };
    const items = [
      ...(Array.isArray(value.messages) ? value.messages as unknown[] : []),
      ...(Array.isArray(value.statuses) ? value.statuses as unknown[] : []),
    ];
    if (
      !items.length ||
      Object.keys(value).some((key) =>
        !["messaging_product", "metadata", "messages", "statuses", "contacts"]
          .includes(key)
      )
    ) return { integration, keys: [] };
    for (const item of items) {
      if (!record(item)) return { integration, keys: [] };
      const customer = item.from ?? item.recipient_id ?? item.recipient_user_id;
      if (typeof customer !== "string" || !/^\d+$/.test(customer)) {
        return { integration, keys: [] };
      }
      keys.push(`${value.metadata.phone_number_id}:${customer}`);
    }
  }
  return { integration, keys: [...new Set(keys)].sort() };
}

export function conflicts(a: Reservation, b: Reservation): boolean {
  return a.integration === "*" || b.integration === "*" ||
    (a.integration === b.integration &&
      (!a.keys.length || !b.keys.length ||
        a.keys.some((key) => b.keys.includes(key))));
}
