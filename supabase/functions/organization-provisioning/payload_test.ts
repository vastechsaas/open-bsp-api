import { assertEquals, assertThrows } from "jsr:@std/assert";
import { organizationProvisioningPayloadSchema } from "./payload.ts";

Deno.test("organization onboarding payload applies safe defaults", () => {
  const payload = organizationProvisioningPayloadSchema.parse({
    request_id: "f1400000-0000-4000-8000-000000000001",
    organization_name: "New Tenant",
    owner: { name: "Owner", email: "owner@example.test" },
  });

  assertEquals(payload.members, []);
  assertEquals(payload.max_agent_seats, null);
  assertEquals(payload.storage_quota_gb, 25);
  assertEquals(payload.auto_assign, false);
});

Deno.test("organization onboarding payload rejects unsupported roles", () => {
  assertThrows(() =>
    organizationProvisioningPayloadSchema.parse({
      request_id: "f1400000-0000-4000-8000-000000000001",
      organization_name: "New Tenant",
      owner: { name: "Owner", email: "owner@example.test" },
      members: [{
        name: "Unknown",
        email: "unknown@example.test",
        role: "billing_admin",
      }],
    })
  );
});
