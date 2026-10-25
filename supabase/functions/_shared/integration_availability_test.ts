import { assertEquals } from "./test_assert.ts";
import {
  type IntegrationAvailabilityClient,
  requireIntegrationAvailable,
} from "./integration_availability.ts";
import { HTTPException } from "jsr:@hono/hono/http-exception";

Deno.test("availability guard fails closed and never exposes database details", async () => {
  for (const integrationId of ["whatsapp", "instagram"] as const) {
    for (
      const [data, error, status] of [[true, null, 200], [false, null, 403], [
        null,
        null,
        403,
      ], [null, { message: "internal-secret" }, 503]] as const
    ) {
      const client = {
        rpc(name: string, args: unknown) {
          assertEquals(name, "is_integration_available");
          assertEquals(args, {
            p_organization_id: "authorized-org",
            p_integration_id: integrationId,
          });
          return Promise.resolve({ data, error });
        },
      } as IntegrationAvailabilityClient;
      let actualStatus = 200;
      try {
        await requireIntegrationAvailable(
          client,
          "authorized-org",
          integrationId,
        );
      } catch (failure) {
        if (!(failure instanceof HTTPException)) throw failure;
        actualStatus = failure.status;
        assertEquals(failure.message.includes("internal-secret"), false);
      }
      assertEquals(actualStatus, status);
    }
  }
});

Deno.test("guards are limited to setup and explicit profile management, not execution/maintenance/disconnect", async () => {
  for (
    const path of [
      "../whatsapp-management/embedded_signup.ts",
      "../instagram-management/login.ts",
    ]
  ) {
    const source = await Deno.readTextFile(new URL(path, import.meta.url));
    const guard = source.indexOf("await requireIntegrationAvailable(");
    assertEquals(guard > 0, true);
    const cleanup = path.includes("embedded_signup")
      ? source.indexOf("export async function deleteSignup")
      : source.indexOf("export async function disconnect");
    assertEquals(
      source.slice(cleanup).includes("await requireIntegrationAvailable("),
      false,
    );
  }
  for (
    const path of [
      "../whatsapp-dispatcher/index.ts",
      "../instagram-dispatcher/index.ts",
      "../whatsapp-webhook/index.ts",
      "../instagram-webhook/index.ts",
    ]
  ) {
    const source = await Deno.readTextFile(new URL(path, import.meta.url));
    assertEquals(source.includes("requireIntegrationAvailable"), false);
  }
});
