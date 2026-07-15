import { assertEquals } from "./test_assert.ts";
import { getWhatsAppErrorDetails, WhatsAppError } from "./whatsapp.ts";

Deno.test("getWhatsAppErrorDetails classifies transient Meta errors", () => {
  const details = getWhatsAppErrorDetails(
    new WhatsAppError("Rate limited", { error: { code: 130429 } }),
  );

  assertEquals(details.isRetryable, true);
  assertEquals(details.metaCode, 130429);
});

Deno.test("getWhatsAppErrorDetails treats validation errors as permanent", () => {
  const details = getWhatsAppErrorDetails(
    new WhatsAppError("Invalid template", { error: { code: 132000 } }),
  );

  assertEquals(details.isRetryable, false);
  assertEquals(details.metaCode, 132000);
});

Deno.test("getWhatsAppErrorDetails retries network and server failures", () => {
  assertEquals(
    getWhatsAppErrorDetails(new TypeError("network unavailable")).isRetryable,
    true,
  );
  assertEquals(
    getWhatsAppErrorDetails(
      new WhatsAppError("Meta unavailable", { status: 503 }),
    ).isRetryable,
    true,
  );
});
