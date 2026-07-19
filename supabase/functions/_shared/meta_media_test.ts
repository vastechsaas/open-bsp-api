import { assertEquals, assertThrows } from "./test_assert.ts";
import {
  getTemplateMediaHeaderFormat,
  stripTemplateMediaHandles,
  uploadMetaResumableMedia,
  validateTemplateMediaSample,
  withTemplateMediaHandle,
} from "./meta_media.ts";
import type { TemplateDraftInput } from "./types/whatsapp_template_types.ts";

const mediaTemplate: TemplateDraftInput = {
  name: "monthly_statement",
  language: "en_US",
  category: "UTILITY",
  components: [
    { type: "HEADER", format: "DOCUMENT" },
    { type: "BODY", text: "Your statement is ready." },
  ],
};

Deno.test("template media handles exist only in the outgoing Meta payload", () => {
  assertEquals(getTemplateMediaHeaderFormat(mediaTemplate), "DOCUMENT");
  const outgoing = withTemplateMediaHandle(mediaTemplate, "meta-handle");
  assertEquals(outgoing.components[0], {
    type: "HEADER",
    format: "DOCUMENT",
    example: { header_handle: ["meta-handle"] },
  });
  assertEquals(stripTemplateMediaHandles(outgoing), mediaTemplate);
});

Deno.test("template media sample validates MIME type, extension, and size", () => {
  const valid = new File([new Uint8Array([1, 2, 3])], "statement.pdf", {
    type: "application/pdf",
  });
  assertEquals(validateTemplateMediaSample(valid, "DOCUMENT"), valid);

  assertThrows(
    () =>
      validateTemplateMediaSample(
        new File([new Uint8Array([1])], "statement.txt", {
          type: "application/pdf",
        }),
        "DOCUMENT",
      ),
    "Template document must be a PDF file",
  );
});

Deno.test("Meta resumable upload returns the temporary handle", async () => {
  const originalFetch = globalThis.fetch;
  const requests: Array<{ url: string; init?: RequestInit }> = [];
  globalThis.fetch = (input, init) => {
    const url = String(input);
    requests.push({ url, init });
    if (url.includes("/app-1/uploads")) {
      return Promise.resolve(Response.json({ id: "upload-session-1" }));
    }
    return Promise.resolve(Response.json({ h: "meta-handle-1" }));
  };

  try {
    const file = new File([new Uint8Array([1, 2, 3])], "promotion.png", {
      type: "image/png",
    });
    assertEquals(
      await uploadMetaResumableMedia("app-1", "token-1", file),
      "meta-handle-1",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }

  assertEquals(requests.length, 2);
  assertEquals(requests[0].url.includes("file_name=promotion.png"), true);
  assertEquals(requests[1].init?.headers, {
    Authorization: "OAuth token-1",
    file_offset: "0",
    "Content-Type": "application/octet-stream",
  });
});
