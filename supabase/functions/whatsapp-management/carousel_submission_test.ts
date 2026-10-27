import { assertEquals } from "../_shared/test_assert.ts";
import { editTemplate, submitTemplateDraft } from "./templates.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../_shared/supabase.ts";
import type {
  TemplateData,
  TemplateDraftInput,
} from "../_shared/types/whatsapp_template_types.ts";

Deno.test("approval submission includes every ordered image handle without internal routing data", async () => {
  const org = "16000000-0000-4000-8000-000000000001";
  const assets = ["a", "b"].map((letter) => ({
    card_id: crypto.randomUUID(),
    storage_uri: `internal://media/organizations/${org}/attachments/${
      letter.repeat(43)
    }`,
    file_name: `${letter}.png`,
    mime_type: "image/png",
    size: 8,
  }));
  const definition: TemplateDraftInput = {
    name: "offers",
    language: "en",
    category: "MARKETING",
    components: [
      { type: "BODY", text: "Explore our offers" },
      {
        type: "CAROUSEL",
        cards: assets.map(() => ({
          components: [
            { type: "HEADER", format: "IMAGE" },
            { type: "BODY", text: "An offer" },
            {
              type: "BUTTONS",
              buttons: [{
                type: "URL",
                text: "Visit",
                url: "https://example.com",
              }],
            },
          ],
        })),
      },
    ],
  };
  let saved: Record<string, unknown> = {};
  const mock = {
    from: (table: string) => {
      const chain = {
        select: () => chain,
        eq: () => chain,
        update: (value: Record<string, unknown>) => {
          saved = value;
          return chain;
        },
        maybeSingle: () =>
          Promise.resolve({
            data: {
              id: "draft",
              status: "draft",
              organization_address: "phone",
              media_assets: assets,
              components: definition.components,
            },
            error: null,
          }),
        single: () =>
          Promise.resolve({
            data: table === "organizations_addresses"
              ? {
                extra: {
                  access_token: "test-token",
                  waba_id: "waba",
                  application_id: "app",
                },
              }
              : saved,
            error: null,
          }),
      };
      return chain;
    },
    storage: {
      from: () => ({
        download: () =>
          Promise.resolve({
            data: new Blob(
              [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])],
              { type: "image/png" },
            ),
            error: null,
          }),
      }),
    },
  } as unknown as SupabaseClient<Database>;
  const original = globalThis.fetch;
  let uploads = 0;
  let submission: TemplateDraftInput | undefined;
  globalThis.fetch = (input, init) => {
    if (String(input).includes("/app/uploads")) {
      return Promise.resolve(Response.json({ id: `upload-${++uploads}` }));
    }
    if (String(input).includes("/upload-")) {
      return Promise.resolve(Response.json({ h: `handle-${uploads}` }));
    }
    submission = JSON.parse(String(init?.body));
    return Promise.resolve(
      Response.json({ id: "remote", status: "PENDING", category: "MARKETING" }),
    );
  };
  try {
    await submitTemplateDraft(mock, org, "draft", definition);
  } finally {
    globalThis.fetch = original;
  }
  assertEquals(uploads, 2);
  const carousel = submission!.components.find((part) =>
    part.type === "CAROUSEL"
  )!;
  assertEquals(
    carousel.cards.map((card) =>
      card.components.find((part) => part.type === "HEADER")?.example
    ),
    [{ header_handle: ["handle-1"] }, { header_handle: ["handle-2"] }],
  );
  assertEquals(JSON.stringify(submission).includes("internal://"), false);
  assertEquals(JSON.stringify(submission).includes("card_id"), false);
  assertEquals(
    JSON.stringify(saved.components).includes("header_handle"),
    false,
  );
  assertEquals((saved.media_assets as Json[]).length, 2);
  let rejected = false;
  try {
    await editTemplate(
      mock,
      org,
      "phone",
      {
        ...definition,
        id: "remote",
        status: "APPROVED",
        components: [{ type: "BODY", text: "Disguised standard template" }],
      } as TemplateData,
    );
  } catch {
    rejected = true;
  }
  assertEquals(rejected, true);
});
