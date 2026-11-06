import { assertEquals } from "../_shared/test_assert.ts";
import { prepareCampaignCarouselMedia } from "./campaign_media.ts";
import { getWhatsAppErrorDetails } from "../_shared/whatsapp.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../_shared/supabase.ts";

const org = "17100000-0000-4000-8000-000000000001";
const assets = ["a", "b"].map((letter) => ({
  card_id: crypto.randomUUID(),
  storage_uri: `internal://media/organizations/${org}/attachments/${
    letter.repeat(43)
  }`,
  file_name: `${letter}.png`,
  mime_type: "image/png",
  size: 8,
}));
const template = {
  name: "offers",
  language: "en_US",
  category: "MARKETING",
  components: [
    { type: "BODY", text: "Our offers" },
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
              text: "Shop",
              url: "https://example.com",
            }],
          },
        ],
      })),
    },
  ],
};

function fixture() {
  const cache = new Map<string, string>();
  let uploads = 0, downloads = 0, metadata = 0;
  let unavailable: string | undefined;
  let outage = false;
  const account = {
    select: () => account,
    eq: () => account,
    maybeSingle: () =>
      Promise.resolve({
        data: { extra: { access_token: "fixture-token" } },
        error: null,
      }),
  };
  const client = {
    from: () => account,
    rpc: (name: string, args: Record<string, string>) => ({
      throwOnError: () => {
        const key = args.p_storage_uri;
        if (name === "claim_campaign_media_cache") {
          const id = cache.get(key);
          return Promise.resolve({
            data: id && id !== args.p_stale_media_id
              ? { state: "ready", media_id: id }
              : { state: "claimed", lease_token: "fixture-lease" },
          });
        }
        if (name === "complete_campaign_media_cache") {
          cache.set(key, args.p_media_id);
        }
        return Promise.resolve({ data: true });
      },
    }),
    storage: {
      from: () => ({
        download: () => {
          downloads++;
          return Promise.resolve({
            data: new Blob(
              [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])],
              { type: "image/png" },
            ),
            error: null,
          });
        },
      }),
    },
  } as unknown as SupabaseClient<Database>;
  const fetch: typeof globalThis.fetch = (input, init) => {
    const url = String(input);
    if (init?.method === "POST" && url.endsWith("/phone/media")) {
      return Promise.resolve(Response.json({ id: String(1000 + ++uploads) }));
    }
    metadata++;
    if (outage) {
      return Promise.resolve(
        Response.json({ error: { code: 2 } }, { status: 503 }),
      );
    }
    const id = new URL(url).pathname.split("/").pop()!;
    if (id === unavailable) {
      unavailable = undefined;
      return Promise.resolve(
        Response.json({ error: { code: 100, error_subcode: 33 } }, {
          status: 400,
        }),
      );
    }
    return Promise.resolve(
      Response.json({
        id,
        url: "https://meta.example/temporary-protected-url",
      }),
    );
  };
  return {
    client,
    fetch,
    cache,
    get uploads() {
      return uploads;
    },
    get downloads() {
      return downloads;
    },
    get metadata() {
      return metadata;
    },
    expire(id: string) {
      unavailable = id;
    },
    failMetadata() {
      outage = true;
    },
    prepare: () =>
      prepareCampaignCarouselMedia(
        client,
        org,
        "phone",
        template as Json,
        assets as Json,
      ),
  };
}

Deno.test("persistent carousel IDs avoid repeated image transfers across independent recipient preparations", async () => {
  const fixtureData = fixture();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fixtureData.fetch;
  try {
    const first = await fixtureData.prepare();
    for (let i = 0; i < 25; i++) {
      assertEquals(await fixtureData.prepare(), first);
    }
    assertEquals(fixtureData.uploads, 2);
    assertEquals(fixtureData.downloads, 2);
    assertEquals(fixtureData.metadata, 50);
    assertEquals(fixtureData.cache.size, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("expired carousel media refreshes only the affected original image", async () => {
  const fixtureData = fixture();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fixtureData.fetch;
  try {
    await fixtureData.prepare();
    fixtureData.expire("1001");
    const next = await fixtureData.prepare() as Array<
      { media_id: string; card_index: number }
    >;
    assertEquals(next.map((card) => [card.card_index, card.media_id]), [[
      0,
      "1003",
    ], [1, "1002"]]);
    assertEquals(fixtureData.uploads, 3);
    assertEquals(fixtureData.downloads, 3);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("Meta outage preserves cached uploads and remains a retryable preparation failure", async () => {
  const fixtureData = fixture();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fixtureData.fetch;
  try {
    await fixtureData.prepare();
    fixtureData.failMetadata();
    let caught: unknown;
    try {
      await fixtureData.prepare();
    } catch (error) {
      caught = error;
    }
    assertEquals(getWhatsAppErrorDetails(caught).isRetryable, true);
    assertEquals(fixtureData.uploads, 2);
    assertEquals(fixtureData.downloads, 2);
    assertEquals([...fixtureData.cache.values()], ["1001", "1002"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
