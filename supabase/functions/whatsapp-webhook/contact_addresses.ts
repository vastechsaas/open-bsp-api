import type { ContactAddressInsert, Json } from "../_shared/supabase.ts";

export const FIRST_INBOUND_MESSAGE_FIELD = "has_inbound_message";

export function contactAddressKey(
  organizationId: string,
  address: string,
  service: string,
): string {
  return `${organizationId}|${address}|${service}`;
}

function jsonObject(value: Json | null | undefined): Record<string, Json> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, Json>
    : {};
}

export function prepareContactAddresses(
  rows: ContactAddressInsert[],
  firstInboundKeys: ReadonlySet<string>,
): ContactAddressInsert[] {
  const deduped = new Map<string, ContactAddressInsert>();

  for (const row of rows) {
    const key = contactAddressKey(
      row.organization_id,
      row.address,
      row.service,
    );
    deduped.set(key, row);
  }

  return Array.from(deduped, ([key, row]) =>
    firstInboundKeys.has(key)
      ? {
        ...row,
        extra: {
          ...jsonObject(row.extra),
          [FIRST_INBOUND_MESSAGE_FIELD]: true,
        },
      }
      : row);
}
