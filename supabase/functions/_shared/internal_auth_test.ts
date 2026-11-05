import { assertEquals } from "./test_assert.ts";
import { hasInternalServiceAuth } from "./internal_auth.ts";

Deno.test("internal authentication accepts configured scheduler and service credentials only", () => {
  const req = (value?: string) =>
    new Request("https://internal", {
      headers: value ? { Authorization: value } : {},
    });
  assertEquals(
    hasInternalServiceAuth(req("Bearer edge"), "edge", "service"),
    true,
  );
  assertEquals(
    hasInternalServiceAuth(req("Bearer service"), "edge", "service"),
    true,
  );
  assertEquals(
    hasInternalServiceAuth(req("Bearer user"), "edge", "service"),
    false,
  );
  assertEquals(hasInternalServiceAuth(req(), undefined, undefined), false);
  assertEquals(hasInternalServiceAuth(req("Bearer "), "", ""), false);
  assertEquals(hasInternalServiceAuth(req("edge"), "edge", "service"), false);
});
