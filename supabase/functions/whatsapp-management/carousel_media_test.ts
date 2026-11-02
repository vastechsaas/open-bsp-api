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
    existingImage?: Blob;
    duplicate?: boolean;
    previewFailure?: boolean;
    uploadError?: unknown;
  } = {},
) {
  let uploads = 0;
  let downloads = 0;
  const stored = new Map<string, Blob>();
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
    get downloads() {
      return downloads;
    },
    stored,
    api: {
      rpc: () =>
        Promise.resolve({
          data: options.authorized === false ? [] : [org],
          error: null,
        }),
      from: () => chain,
      storage: {
        from: () => ({
          upload: (key: string, file: Blob, settings: { upsert: boolean }) => {
            uploads++;
            assertEquals(settings.upsert, false);
            const error = options.uploadError ||
              (options.quota
                ? { message: "media storage quota exceeded" }
                : null) ||
              (options.duplicate || stored.has(key)
                ? { statusCode: "409", message: "The resource already exists" }
                : null);
            if (!error) stored.set(key, file);
            return Promise.resolve({
              error,
            });
          },
          createSignedUrl: () =>
            Promise.resolve({
              data: { signedUrl: "https://example.test/private-preview" },
              error: options.previewFailure
                ? new Error("Preview failed")
                : null,
            }),
          download: (key: string) => {
            downloads++;
            return Promise.resolve({
              data: options.existingImage || stored.get(key) || png(),
              error: options.missingImage ? new Error("Missing image") : null,
            });
          },
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

const upload = (mock: ReturnType<typeof client>, organizationId = org) =>
  uploadCarouselImage(
    mock.api,
    organizationId,
    "campaign",
    crypto.randomUUID(),
    crypto.randomUUID(),
    png(),
  );

Deno.test("identical carousel images and concurrent retries reuse tenant bytes without update grants", async () => {
  const mock = client();
  const results = await Promise.all([upload(mock), upload(mock), upload(mock)]);
  assertEquals(
    new Set(results.map((result) => result.asset.storage_uri)).size,
    1,
  );
  assertEquals(mock.stored.size, 1);
  assertEquals(mock.downloads, 2);
  assertEquals(new Set(results.map((result) => result.asset.card_id)).size, 3);
  const other = await upload(mock, crypto.randomUUID());
  assertEquals(other.asset.storage_uri === results[0].asset.storage_uri, false);
  assertEquals(mock.stored.size, 2);
});

Deno.test("duplicate conflicts require readable matching bytes, type and size", async () => {
  for (
    const options of [
      { missingImage: true },
      { existingImage: new Blob(["different"], { type: "image/png" }) },
      { existingImage: new Blob([new Uint8Array(8)], { type: "image/png" }) },
      {
        existingImage: new Blob([await png().arrayBuffer()], {
          type: "image/jpeg",
        }),
      },
    ]
  ) {
    const mock = client({ duplicate: true, ...options });
    try {
      await upload(mock);
      throw new Error("Expected rejection");
    } catch (error) {
      assertEquals((error as Error).cause, {
        code: "carousel_image_reuse_failed",
      });
    }
    assertEquals(mock.stored.size, 0);
  }
});

Deno.test("upload and preview errors expose safe retry codes, not storage internals", async () => {
  for (
    const [options, code] of [
      [{ quota: true }, "carousel_storage_quota_exceeded"],
      [{
        uploadError: { statusCode: "403", message: "private storage details" },
      }, "carousel_upload_failed"],
      [{ previewFailure: true }, "carousel_preview_failed"],
    ] as const
  ) {
    const mock = client(options);
    try {
      await upload(mock);
      throw new Error("Expected rejection");
    } catch (error) {
      assertEquals((error as Error).cause, { code });
      assertEquals((error as Error).message.includes("private storage"), false);
    }
    assertEquals(mock.downloads, 0);
  }
  const mock = client({ previewFailure: true });
  await rejects(() => upload(mock));
  await rejects(() => upload(mock));
  assertEquals(mock.stored.size, 1);
  assertEquals(mock.downloads, 1);
});
