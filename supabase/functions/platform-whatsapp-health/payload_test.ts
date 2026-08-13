import { assertEquals, assertThrows } from "jsr:@std/assert";
import {
  ACTION_AUDIT_TYPES,
  platformWhatsAppHealthPayloadSchema,
} from "./payload.ts";

Deno.test("platform WABA health payload accepts the supported actions", () => {
  for (const action of Object.keys(ACTION_AUDIT_TYPES)) {
    const value = platformWhatsAppHealthPayloadSchema.parse({
      organization_id: "10000000-0000-4000-8000-000000000001",
      phone_number_id: "123456789",
      action,
      request_id: "20000000-0000-4000-8000-000000000001",
    });
    assertEquals(value.action, action);
  }
});

Deno.test("platform WABA health payload rejects unknown actions and fields", () => {
  assertThrows(() =>
    platformWhatsAppHealthPayloadSchema.parse({
      organization_id: "10000000-0000-4000-8000-000000000001",
      phone_number_id: "123456789",
      action: "reconnect",
      request_id: "20000000-0000-4000-8000-000000000001",
    })
  );
  assertThrows(() =>
    platformWhatsAppHealthPayloadSchema.parse({
      organization_id: "10000000-0000-4000-8000-000000000001",
      phone_number_id: "123456789",
      action: "test_connection",
      request_id: "20000000-0000-4000-8000-000000000001",
      access_token: "secret",
    })
  );
});
