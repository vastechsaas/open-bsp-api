import { encodeBase64 } from "jsr:@std/encoding/base64";
import { encodeBase64Url } from "jsr:@std/encoding/base64url";

type Failure = {
  outcome: "temporary" | "credentials" | "unavailable" | "too_large";
  retryAfter?: number;
};

type Recovered = {
  outcome: "ready";
  bytes: Uint8Array<ArrayBuffer>;
  mime: string;
  digest: string;
};

function retryAfter(response: Response): number {
  const value = response.headers.get("Retry-After")?.trim();
  if (!value) return 0;
  const seconds = /^\d+$/.test(value)
    ? Number(value)
    : Math.ceil((Date.parse(value) - Date.now()) / 1000);
  return Number.isFinite(seconds) ? Math.min(86400, Math.max(0, seconds)) : 0;
}

async function boundedBytes(response: Response, size: number) {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const bytes = new Uint8Array(size);
  let offset = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return offset === size ? bytes : null;
      if (offset + value.length > size) {
        await reader.cancel();
        return null;
      }
      bytes.set(value, offset);
      offset += value.length;
    }
  } finally {
    reader.releaseLock();
  }
}

export async function fetchWhatsAppAttachment(
  args: {
    mediaId: string;
    phoneNumberId: string;
    token: string;
    limit: number;
  },
  fetcher: typeof fetch = fetch,
): Promise<Failure | Recovered> {
  if (!args.token) return { outcome: "credentials" };
  const graph = new URL(`https://graph.facebook.com/v24.0/${args.mediaId}`);
  graph.searchParams.set("phone_number_id", args.phoneNumberId);
  const headers = { Authorization: `Bearer ${args.token}` };
  try {
    const lookup = await fetcher(graph, {
      headers,
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
    });
    if (!lookup.ok) {
      const data = await lookup.json().catch(() => null);
      const code = data?.error?.code;
      if (
        code === 190 || code === 10 || code === 200 ||
        lookup.status === 401 || lookup.status === 403
      ) return { outcome: "credentials" };
      // Graph's generic object/permission error is not proof of expiration.
      // Only a specific media-not-found/deleted error or HTTP Gone is terminal.
      if (
        lookup.status === 410 ||
        ((lookup.status === 400 || lookup.status === 404) &&
          typeof data?.error?.message === "string" &&
          /^(?:media(?: object| id| file)?(?: was)? (?:not found|deleted|has expired)|media(?: object| id| file)? does not exist)\.?$/i
            .test(data.error.message.trim()))
      ) return { outcome: "unavailable" };
      return { outcome: "temporary", retryAfter: retryAfter(lookup) };
    }
    const data = await lookup.json();
    const size = typeof data.file_size === "string" &&
        /^[0-9]+$/.test(data.file_size)
      ? Number(data.file_size)
      : data.file_size;
    const mime = typeof data.mime_type === "string"
      ? data.mime_type.split(";", 1)[0].trim().toLowerCase()
      : "";
    if (Number.isSafeInteger(size) && size > args.limit) {
      return { outcome: "too_large" };
    }
    if (
      data.id !== args.mediaId || !Number.isSafeInteger(size) || size <= 0 ||
      typeof data.sha256 !== "string" ||
      !/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/.test(mime)
    ) return { outcome: "temporary" };

    const url = new URL(data.url);
    if (
      url.protocol !== "https:" || url.hostname !== "lookaside.fbsbx.com" ||
      url.port || url.username || url.password
    ) return { outcome: "temporary" };
    const file = await fetcher(url, {
      headers,
      redirect: "error",
      signal: AbortSignal.timeout(25_000),
    });
    // URLs can expire or be rejected even when metadata and credentials are
    // valid. Retry from the Graph lookup rather than treating the file as gone.
    if (!file.ok) {
      await file.body?.cancel();
      return { outcome: "temporary", retryAfter: retryAfter(file) };
    }
    const bytes = await boundedBytes(file, size);
    if (!bytes) return { outcome: "temporary" };
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0"))
      .join("");
    const encoded = encodeBase64Url(digest).replace(/=+$/, "");
    if (
      data.sha256.toLowerCase() !== hex &&
      data.sha256 !== encodeBase64(digest) &&
      data.sha256.replace(/=+$/, "") !== encoded
    ) return { outcome: "temporary" };
    return { outcome: "ready", bytes, mime, digest: encoded };
  } catch {
    // Fetch and parser errors can contain a signed URL; never propagate them.
    return { outcome: "temporary" };
  }
}
