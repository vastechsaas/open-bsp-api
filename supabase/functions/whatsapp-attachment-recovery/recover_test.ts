import { assertEquals } from "jsr:@std/assert";
import { fetchWhatsAppAttachment } from "./recover.ts";

const input = {
  mediaId: "12345",
  phoneNumberId: "54321",
  token: "fixture-only",
  limit: 64,
};
const meta = {
  id: input.mediaId,
  file_size: 3,
  mime_type: "image/jpeg",
  sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  url: "https://lookaside.fbsbx.com/short-lived?nonce=fixture",
};

Deno.test("verified download gets a fresh account-scoped Meta URL", async () => {
  const hosts: string[] = [];
  const result = await fetchWhatsAppAttachment(input, (url, init) => {
    const u = new URL(String(url));
    hosts.push(u.hostname);
    assertEquals(init?.redirect, "error");
    assertEquals(
      new Headers(init?.headers).get("Authorization"),
      "Bearer fixture-only",
    );
    if (u.hostname === "graph.facebook.com") {
      assertEquals(u.searchParams.get("phone_number_id"), input.phoneNumberId);
      return Promise.resolve(Response.json(meta));
    }
    return Promise.resolve(new Response("abc"));
  });
  assertEquals(result.outcome, "ready");
  assertEquals(hosts, ["graph.facebook.com", "lookaside.fbsbx.com"]);
});

Deno.test("CDN timeout/expiration retry without exposing the URL", async () => {
  for (const expired of [true, false]) {
    const result = await fetchWhatsAppAttachment(input, (url) => {
      if (String(url).startsWith("https://graph.facebook.com/")) {
        return Promise.resolve(Response.json(meta));
      }
      return expired
        ? Promise.resolve(new Response(null, { status: 404 }))
        : Promise.reject(new Error("signed CDN URL timed out"));
    });
    assertEquals(result.outcome, "temporary");
    assertEquals(JSON.stringify(result).includes("URL"), false);
  }
});

Deno.test("Meta voice MIME parameters and numeric size strings are supported", async () => {
  const result = await fetchWhatsAppAttachment(input, (url) =>
    Promise.resolve(
      String(url).startsWith("https://graph.facebook.com/")
        ? Response.json({
          ...meta,
          mime_type: "audio/ogg; codecs=opus",
          file_size: "3",
        })
        : new Response("abc"),
    ));
  assertEquals(result.outcome, "ready");
  if (result.outcome === "ready") assertEquals(result.mime, "audio/ogg");
});

Deno.test("rate limits, invalid credentials, and confirmed loss differ", async () => {
  const respond = (message: string, code: number, status: number) => () =>
    Promise.resolve(Response.json({ error: { message, code } }, {
      status,
      headers: { "Retry-After": "90" },
    }));
  assertEquals(await fetchWhatsAppAttachment(input, respond("rate", 4, 429)), {
    outcome: "temporary",
    retryAfter: 90,
  });
  assertEquals(
    (await fetchWhatsAppAttachment(input, respond("expired token", 190, 400)))
      .outcome,
    "credentials",
  );
  assertEquals(
    (await fetchWhatsAppAttachment(
      input,
      respond("unsupported object", 100, 400),
    )).outcome,
    "temporary",
  );
  assertEquals(
    (await fetchWhatsAppAttachment(
      input,
      respond("Media not found.", 100, 404),
    )).outcome,
    "unavailable",
  );
});

Deno.test("size, digest, and host must be valid; secrets never reach an unexpected host", async () => {
  for (
    const data of [
      { ...meta, url: "https://lookaside.fbsbx.com.example.test/" },
      { ...meta, file_size: 65 },
      { ...meta, sha256: "wrong" },
      meta,
    ]
  ) {
    let requests = 0;
    const result = await fetchWhatsAppAttachment(
      input,
      () =>
        Promise.resolve(
          ++requests === 1 ? Response.json(data) : new Response("too long"),
        ),
    );
    assertEquals(
      result.outcome,
      data.file_size > 64 ? "too_large" : "temporary",
    );
    if (data.file_size > 64 || data.url.endsWith("example.test/")) {
      assertEquals(requests, 1);
    }
  }
});
