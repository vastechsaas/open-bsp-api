import { assertEquals, assertRejects } from "jsr:@std/assert";
import {
  type Receipt,
  retainCampaignReceipt,
  retainReceiptOnlyBatch,
} from "./campaign_receipts.ts";
import type { MetaWebhookPayload } from "../_shared/types/whatsapp_webhook_payload_types.ts";

Deno.test("receipt adapter sends safe correlation, not recipient/content/errors", async () => {
  let captured: Receipt | undefined;
  const result = await retainCampaignReceipt(
    (receipt) => {
      captured = receipt;
      return Promise.resolve(true);
    },
    "org",
    "sender",
    {
      id: "wamid",
      status: "read",
      timestamp: "1793527200",
      recipient_id: "private-phone",
      biz_opaque_callback_data: "campaign:job:id",
    },
  );
  assertEquals(result, true);
  assertEquals(captured, {
    p_organization_id: "org",
    p_organization_address: "sender",
    p_external_id: "wamid",
    p_receipt_type: "read",
    p_provider_at: new Date(1793527200000).toISOString(),
    p_correlation: "campaign:job:id",
  });
});
Deno.test("genuine chat status remains on its existing handler", async () => {
  assertEquals(
    await retainCampaignReceipt(() => Promise.resolve(false), "org", "sender", {
      id: "chat",
      status: "sent",
      timestamp: "10",
    }),
    false,
  );
});
Deno.test("database failure propagates so webhook can be retried", async () => {
  await assertRejects(() =>
    retainCampaignReceipt(
      () => Promise.reject(new Error("unavailable")),
      "org",
      "sender",
      {
        id: "wamid",
        status: "delivered",
        timestamp: "10",
      },
    )
  );
});
Deno.test("invalid provider time is not acknowledged", async () => {
  await assertRejects(() =>
    retainCampaignReceipt(() => Promise.resolve(true), "org", "sender", {
      id: "wamid",
      status: "read",
      timestamp: "bad",
    })
  );
});

const batch = (phones: string[]) =>
  ({
    object: "whatsapp_business_account",
    entry: [{
      id: "waba",
      changes: [
        { field: "account_update", value: { event: "PARTNER_REMOVED" } },
        ...phones.map((phone) => ({
          field: "messages",
          value: {
            metadata: { phone_number_id: phone },
            messages: [{
              id: "must-not-be-processed",
              text: { body: "hello" },
            }],
            statuses: [{ id: "receipt", status: "read", timestamp: "10" }],
          },
        })),
      ],
    }],
  }) as unknown as MetaWebhookPayload;

Deno.test("receipt-only mixed batch retains statuses, not input or account changes", async () => {
  const calls: Receipt[] = [];
  assertEquals(
    await retainReceiptOnlyBatch(
      batch(["number"]),
      "org",
      new Map([["number", { organization_id: "org", address: "number" }]]),
      (receipt) => {
        calls.push(receipt);
        return Promise.resolve(true);
      },
    ),
    true,
  );
  assertEquals(calls.length, 1);
  assertEquals(calls[0].p_external_id, "receipt");
});

Deno.test("mixed-tenant receipt batch is rejected before writing any receipt", async () => {
  let calls = 0;
  assertEquals(
    await retainReceiptOnlyBatch(
      batch(["number", "other"]),
      "org",
      new Map([["number", { organization_id: "org", address: "number" }], [
        "other",
        { organization_id: "other-org", address: "other" },
      ]]),
      () => {
        calls++;
        return Promise.resolve(true);
      },
    ),
    false,
  );
  assertEquals(calls, 0);
});
