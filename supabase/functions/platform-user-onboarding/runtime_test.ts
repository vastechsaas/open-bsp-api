import { assertEquals, assertThrows } from "jsr:@std/assert";
import { assertAccountSetupConfigured } from "./runtime.ts";
import { SafeFailure } from "./core.ts";

Deno.test("only explicitly configured staging and Main setup callbacks permit account creation", () => {
  const previous = Deno.env.get("PLATFORM_ONBOARDING_CALLBACK_URL");
  try {
    for (
      const url of [
        "https://vistagalaxy.vastech.biz/onboard/set-password",
        "https://socialconnect.vastech.biz/onboard/set-password",
      ]
    ) {
      Deno.env.set("PLATFORM_ONBOARDING_CALLBACK_URL", url);
      assertEquals(assertAccountSetupConfigured("create"), undefined);
    }
    for (
      const url of [
        "",
        "https://other.example/onboard/set-password",
        "https://socialconnect.vastech.biz.evil.example/onboard/set-password",
      ]
    ) {
      Deno.env.set("PLATFORM_ONBOARDING_CALLBACK_URL", url);
      assertThrows(
        () => assertAccountSetupConfigured("create"),
        SafeFailure,
        "ONBOARDING_NOT_CONFIGURED",
      );
    }
    Deno.env.delete("PLATFORM_ONBOARDING_CALLBACK_URL");
    for (const action of ["preview", "status", "complete"]) {
      assertEquals(assertAccountSetupConfigured(action), undefined);
    }
  } finally {
    if (previous === undefined) {
      Deno.env.delete("PLATFORM_ONBOARDING_CALLBACK_URL");
    } else Deno.env.set("PLATFORM_ONBOARDING_CALLBACK_URL", previous);
  }
});
