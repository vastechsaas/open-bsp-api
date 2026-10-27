import { assertEquals } from "../_shared/test_assert.ts";
import { loadCarouselImages, uploadCarouselImage } from "./carousel_media.ts";
import type { Database } from "../_shared/supabase.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

const org = "16000000-0000-4000-8000-000000000001";
const png = () =>
  new File([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])], "image.png", {
    type: "image/png",
  });
function client(
  options: {
    authorized?: boolean;
    missingDraft?: boolean;
    quota?: boolean;
    missingImage?: boolean;
  } = {},
) {
  let uploads = 0;
  const chain = {
    select: () => chain,
    eq: () => chain,
    maybeSingle: () =>
      Promise.resolve({
        data: options.missingDraft ? null : { id: "draft" },
        error: null,
      }),
  };
  return {
    get uploads() {
      return uploads;
    },
    api: {
      rpc: () =>
        Promise.resolve({
          data: options.authorized === false ? [] : [org],
          error: null,
        }),
      from: () => chain,
      storage: {
        from: () => ({
          upload: () => {
            uploads++;
            return Promise.resolve({
              error: options.quota ? new Error("Quota exceeded") : null,
            });
          },
          createSignedUrl: () =>
            Promise.resolve({
              data: { signedUrl: "https://example.test/private-preview" },
              error: null,
            }),
          download: () =>
            Promise.resolve({
              data: png(),
              error: options.missingImage ? new Error("Missing image") : null,
            }),
        }),
      },
    } as unknown as SupabaseClient<Database>,
  };
}
async function rejects(fn: () => Promise<unknown>) {
  let rejected = false;
  try {
    await fn();
  } catch {
    rejected = true;
  }
  assertEquals(rejected, true);
}
Deno.test("carousel image upload requires template management and an accessible draft", async () => {
  for (const options of [{ authorized: false }, { missingDraft: true }]) {
    const mock = client(options);
    await rejects(() =>
      uploadCarouselImage(
        mock.api,
        org,
        "template",
        crypto.randomUUID(),
        crypto.randomUUID(),
        png(),
      )
    );
    assertEquals(mock.uploads, 0);
  }
});
Deno.test("invalid file content is rejected before writing private storage", async () => {
  const mock = client();
  await rejects(() =>
    uploadCarouselImage(
      mock.api,
      org,
      "template",
      crypto.randomUUID(),
      crypto.randomUUID(),
      new File(["not an image"], "image.png", { type: "image/png" }),
    )
  );
  assertEquals(mock.uploads, 0);
});
Deno.test("private carousel assets retain durable references and obey quota failures", async () => {
  const mock = client();
  const id = crypto.randomUUID();
  const result = await uploadCarouselImage(
    mock.api,
    org,
    "template",
    crypto.randomUUID(),
    id,
    png(),
  );
  assertEquals(result.asset.card_id, id);
  assertEquals(
    result.asset.storage_uri.startsWith(
      `internal://media/organizations/${org}/attachments/`,
    ),
    true,
  );
  assertEquals(mock.uploads, 1);
  await rejects(() =>
    uploadCarouselImage(
      client({ quota: true }).api,
      org,
      "campaign",
      crypto.randomUUID(),
      id,
      png(),
    )
  );
  const files = await loadCarouselImages(mock.api, org, [result.asset], 1);
  assertEquals(files.length, 1);
  await rejects(() =>
    loadCarouselImages(
      client({ missingImage: true }).api,
      org,
      [result.asset],
      1,
    )
  );
  await rejects(() =>
    loadCarouselImages(mock.api, crypto.randomUUID(), [result.asset], 1)
  );
});
