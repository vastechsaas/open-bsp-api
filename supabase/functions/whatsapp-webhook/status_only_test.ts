import { assertEquals } from "jsr:@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/supabase.ts";
import { parseStatusOnly, processStatusOnly } from "./status_only.ts";

function payload() {
  return {
    object: "whatsapp_business_account",
    entry: [{
      changes: [{
        field: "messages",
        value: {
          metadata: { phone_number_id: "12345" },
          statuses: [{
            id: "wamid.x",
            recipient_id: "923000001",
            status: "read",
            timestamp: "1791700000",
          }],
        },
      }],
    }],
  };
}
function mock(rows: unknown[]) {
  const updates: unknown[] = [];
  let writing = false;
  const query = {
    select: () => query,
    eq: () => query,
    in: () => Promise.resolve({ data: rows, error: null }),
    update: (value: unknown) => {
      writing = true;
      updates.push(value);
      return query;
    },
    maybeSingle: () =>
      Promise.resolve({ data: writing ? { id: "m" } : null, error: null }),
  };
  return {
    updates,
    client: { from: () => query } as unknown as SupabaseClient<Database>,
  };
}
Deno.test("status-only rejects mixed and malformed input", () => {
  const body = payload();
  assertEquals(parseStatusOnly(body)?.length, 1);
  (body.entry[0].changes[0].value as Record<string, unknown>).messages = [];
  assertEquals(parseStatusOnly(body), undefined);
});
Deno.test("missing original retries without creating placeholders", async () => {
  const { client, updates } = mock([]);
  assertEquals(
    (await processStatusOnly(payload(), "org", new Set(["12345"]), client))
      .status,
    503,
  );
  assertEquals(updates, []);
});
Deno.test("known identity metadata is status-only; unfamiliar contacts remain rejected", () => {
  const body = payload();
  const value = body.entry[0].changes[0].value as Record<string, unknown>;
  value.contacts = [{ wa_id: "923000001", user_id: "identity" }];
  assertEquals(parseStatusOnly(body)?.length, 1);
  value.contacts = [{ wa_id: "923000001", unfamiliar: {} }];
  assertEquals(parseStatusOnly(body), undefined);
});
Deno.test("tenant mismatch rejected before writing", async () => {
  const { client, updates } = mock([]);
  assertEquals(
    (await processStatusOnly(payload(), "org", new Set(["67890"]), client))
      .status,
    403,
  );
  assertEquals(updates, []);
});
Deno.test("only status changes; original content, conversation and timestamps untouched", async () => {
  const { client, updates } = mock([{
    id: "m",
    external_id: "wamid.x",
    organization_address: "12345",
    contact_address: "923000001",
    direction: "outgoing",
    service: "whatsapp",
  }]);
  assertEquals(
    (await processStatusOnly(payload(), "org", new Set(["12345"]), client))
      .status,
    200,
  );
  assertEquals(updates, [{
    status: { read: new Date(1791700000 * 1000).toISOString() },
  }]);
});
