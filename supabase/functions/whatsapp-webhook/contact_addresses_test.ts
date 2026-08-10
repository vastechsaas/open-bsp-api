import { assertEquals } from "../_shared/test_assert.ts";
import type { ContactAddressInsert } from "../_shared/supabase.ts";
import {
  contactAddressKey,
  prepareContactAddresses,
} from "./contact_addresses.ts";

const organizationId = "10000000-0000-4000-8000-000000000001";

Deno.test("only real incoming WhatsApp identities receive the first-message marker", () => {
  const incomingKey = contactAddressKey(
    organizationId,
    "923001111111",
    "whatsapp",
  );
  const rows: ContactAddressInsert[] = [
    {
      organization_id: organizationId,
      address: "923001111111",
      service: "whatsapp",
      extra: { name: "Ali" },
    },
    {
      organization_id: organizationId,
      address: "923002222222",
      service: "whatsapp",
      extra: { name: "Status Recipient" },
    },
  ];

  assertEquals(prepareContactAddresses(rows, new Set([incomingKey])), [
    {
      ...rows[0],
      extra: { name: "Ali", has_inbound_message: true },
    },
    rows[1],
  ]);
});

Deno.test("deduplication cannot discard an incoming marker", () => {
  const key = contactAddressKey(
    organizationId,
    "923003333333",
    "whatsapp",
  );
  const rows: ContactAddressInsert[] = [
    {
      organization_id: organizationId,
      address: "923003333333",
      service: "whatsapp",
      extra: { name: "First payload" },
    },
    {
      organization_id: organizationId,
      address: "923003333333",
      service: "whatsapp",
      extra: { name: "Latest payload" },
    },
  ];

  assertEquals(prepareContactAddresses(rows, new Set([key])), [{
    ...rows[1],
    extra: { name: "Latest payload", has_inbound_message: true },
  }]);
});
