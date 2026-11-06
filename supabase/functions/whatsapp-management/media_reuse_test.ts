import { assertEquals } from "../_shared/test_assert.ts";
import {
  type MediaReuseDependencies,
  missingMediaReference,
  reuseCampaignMedia,
} from "./media_reuse.ts";

Deno.test("only definitive missing-object metadata responses invalidate cached media", () => {
  assertEquals(missingMediaReference(404), true);
  assertEquals(missingMediaReference(410), true);
  assertEquals(missingMediaReference(400, 100, 33), true);
  for (const status of [401, 403, 429, 500, 502, 503]) {
    assertEquals(missingMediaReference(status, 190), false);
  }
  assertEquals(missingMediaReference(400, 100), false);
  assertEquals(missingMediaReference(400, 190), false);
});

async function assertRejects(
  callback: () => Promise<unknown>,
  expected: typeof TypeError,
) {
  try {
    await callback();
  } catch (error) {
    if (error instanceof expected) return;
    throw error;
  }
  throw new Error("Expected preparation to reject");
}

function fixture(overrides: Partial<MediaReuseDependencies> = {}) {
  const calls: string[] = [];
  const deps: MediaReuseDependencies = {
    claim: () => Promise.resolve({ state: "claimed", lease_token: "token" }),
    available: (id) => {
      calls.push(`available:${id}`);
      return Promise.resolve(true);
    },
    upload: () => {
      calls.push("upload");
      return Promise.resolve("123");
    },
    complete: (token, id) => {
      calls.push(`complete:${token}:${id}`);
      return Promise.resolve(true);
    },
    release: (token) => {
      calls.push(`release:${token}`);
      return Promise.resolve(true);
    },
    wait: () => Promise.resolve(),
    ...overrides,
  };
  return { deps, calls };
}

Deno.test("cache miss uploads once and commits before returning the ID", async () => {
  const { deps, calls } = fixture();
  assertEquals(await reuseCampaignMedia(deps), "123");
  assertEquals(calls, ["upload", "complete:token:123"]);
});

Deno.test("valid cached media reuses its ID without downloading/uploading original bytes", async () => {
  const { deps, calls } = fixture({
    claim: () => Promise.resolve({ state: "ready", media_id: "456" }),
  });
  for (let recipient = 0; recipient < 100; recipient++) {
    assertEquals(await reuseCampaignMedia(deps), "456");
  }
  assertEquals(calls.length, 100);
  assertEquals(calls.every((call) => call === "available:456"), true);
});

Deno.test("definitively missing media is replaced using a compare-and-swap claim", async () => {
  const claims: (string | undefined)[] = [];
  const { deps, calls } = fixture({
    claim: (stale) => {
      claims.push(stale);
      return Promise.resolve(
        stale
          ? { state: "claimed", lease_token: "refresh" }
          : { state: "ready", media_id: "456" },
      );
    },
    available: () => Promise.resolve(false),
  });
  assertEquals(await reuseCampaignMedia(deps), "123");
  assertEquals(claims, [undefined, "456"]);
  assertEquals(calls, ["upload", "complete:refresh:123"]);
});

Deno.test("transient validation failure keeps cache and does not upload", async () => {
  const { deps, calls } = fixture({
    claim: () => Promise.resolve({ state: "ready", media_id: "456" }),
    available: () => Promise.reject(new TypeError("network unavailable")),
  });
  await assertRejects(() => reuseCampaignMedia(deps), TypeError);
  assertEquals(calls, []);
});

Deno.test("failed upload releases only its own lease", async () => {
  const { deps, calls } = fixture({
    upload: () => Promise.reject(new TypeError("upload unavailable")),
  });
  await assertRejects(() => reuseCampaignMedia(deps), TypeError);
  assertEquals(calls, ["release:token"]);
});

Deno.test("stale uploader cannot use an uncommitted media ID", async () => {
  const { deps, calls } = fixture({ complete: () => Promise.resolve(false) });
  await assertRejects(() => reuseCampaignMedia(deps), TypeError);
  assertEquals(calls, ["upload", "release:token"]);
});

Deno.test("competing preparation waits for ready media without another upload", async () => {
  let busy = true;
  const { deps, calls } = fixture({
    claim: () =>
      Promise.resolve(
        busy ? { state: "busy" } : { state: "ready", media_id: "456" },
      ),
    wait: () => {
      busy = false;
      return Promise.resolve();
    },
  });
  assertEquals(await reuseCampaignMedia(deps), "456");
  assertEquals(calls, ["available:456"]);
});

Deno.test("busy waits are bounded and never download or upload", async () => {
  let waits = 0;
  const { deps, calls } = fixture({
    claim: () => Promise.resolve({ state: "busy" }),
    wait: () => {
      waits++;
      return Promise.resolve();
    },
  });
  await assertRejects(() => reuseCampaignMedia(deps), TypeError);
  assertEquals(waits, 20);
  assertEquals(calls, []);
});
