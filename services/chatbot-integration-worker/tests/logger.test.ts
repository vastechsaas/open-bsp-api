import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeFields } from "../src/logger.js";

test("redacts credentials, signatures and raw payload fields", () => {
  assert.deepEqual(
    sanitizeFields({
      event_id: "safe",
      api_key: "secret",
      Authorization: "Bearer secret",
      signature: "sha256=secret",
      raw_body: "customer data",
      payload: { sensitive: true },
    }),
    {
      event_id: "safe",
      api_key: "[REDACTED]",
      Authorization: "[REDACTED]",
      signature: "[REDACTED]",
      raw_body: "[REDACTED]",
      payload: "[REDACTED]",
    },
  );
});
