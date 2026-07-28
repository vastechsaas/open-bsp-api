import {
  CHATBOT_WEBHOOK_BODY_MAX_LENGTH,
  type JsonValue,
  type WebhookExecutionResultV1,
  type WebhookExecutorV1,
  type WebhookNodeV1,
} from "./flow_definition.ts";
import { renderChatbotTemplate } from "./template.ts";

export const CHATBOT_WEBHOOK_MAX_RESPONSE_BYTES = 64 * 1024;
export const CHATBOT_WEBHOOK_MAX_REDIRECTS = 3;

export type WebhookSecretResolver = (
  secretId: string,
) => Promise<Readonly<Record<string, string>> | null>;

export interface WebhookExecutorDependencies {
  readonly resolveSecret: WebhookSecretResolver;
  readonly idempotencyKey: string;
  readonly fetchImpl?: typeof fetch;
  readonly resolveDns?: (
    hostname: string,
    recordType: "A" | "AAAA",
  ) => Promise<string[]>;
}

function ipv4Parts(value: string): number[] | null {
  const parts = value.split(".");
  if (parts.length !== 4) return null;
  const numbers = parts.map(Number);
  return numbers.every((part) =>
      Number.isInteger(part) && part >= 0 && part <= 255
    )
    ? numbers
    : null;
}

export function isPrivateOrLocalAddress(address: string): boolean {
  const ipv4 = ipv4Parts(address);
  if (ipv4) {
    const [a, b] = ipv4;
    return a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 100 && b >= 64 && b <= 127) ||
      a >= 224;
  }

  const normalized = address.toLowerCase().split("%")[0];
  if (!normalized.includes(":")) return true;
  return normalized === "::" ||
    normalized === "::1" ||
    normalized === "0:0:0:0:0:0:0:0" ||
    normalized === "0:0:0:0:0:0:0:1" ||
    normalized.startsWith("fc") ||
    normalized.startsWith("fd") ||
    normalized.startsWith("fe8") ||
    normalized.startsWith("fe9") ||
    normalized.startsWith("fea") ||
    normalized.startsWith("feb") ||
    normalized.startsWith("ff") ||
    normalized.startsWith("::ffff:") ||
    normalized.startsWith("0:0:0:0:0:ffff:") ||
    normalized.startsWith("64:ff9b:");
}

async function defaultResolveDns(
  hostname: string,
  recordType: "A" | "AAAA",
): Promise<string[]> {
  try {
    return await Deno.resolveDns(hostname, recordType);
  } catch {
    return [];
  }
}

export async function validateWebhookUrl(
  value: string,
  resolveDns = defaultResolveDns,
): Promise<URL> {
  const url = new URL(value);
  if (url.protocol !== "https:") {
    throw new Error("Only HTTPS webhook URLs are allowed");
  }
  if (url.username || url.password) {
    throw new Error("Webhook URLs must not contain credentials");
  }

  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal")
  ) {
    throw new Error("Local webhook hosts are blocked");
  }

  const literal = ipv4Parts(hostname) || hostname.includes(":");
  const addresses = literal ? [hostname] : [
    ...await resolveDns(hostname, "A"),
    ...await resolveDns(hostname, "AAAA"),
  ];
  if (addresses.length === 0) {
    throw new Error("Webhook host could not be resolved");
  }
  if (addresses.some(isPrivateOrLocalAddress)) {
    throw new Error(
      "Private, local, link-local, and metadata targets are blocked",
    );
  }

  return url;
}

async function readBoundedResponse(response: Response): Promise<string> {
  const contentLength = Number(response.headers.get("content-length"));
  if (
    Number.isFinite(contentLength) &&
    contentLength > CHATBOT_WEBHOOK_MAX_RESPONSE_BYTES
  ) {
    throw new Error("Webhook response is too large");
  }
  if (!response.body) return "";

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > CHATBOT_WEBHOOK_MAX_RESPONSE_BYTES) {
      await reader.cancel();
      throw new Error("Webhook response is too large");
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function valueAtPath(value: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((current, part) => {
    if (
      typeof current !== "object" ||
      current === null ||
      Array.isArray(current)
    ) {
      return undefined;
    }
    return (current as Record<string, unknown>)[part];
  }, value);
}

function scalar(value: unknown): value is JsonValue {
  return value === null ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean";
}

export function mapWebhookResponse(
  node: Readonly<WebhookNodeV1>,
  responseBody: unknown,
): WebhookExecutionResultV1 {
  const variableUpdates: Record<string, JsonValue> = {};
  for (const mapping of node.config.response_mappings) {
    const value = valueAtPath(responseBody, mapping.path);
    if (!scalar(value)) {
      return errorResult("webhook_response_mapping_invalid");
    }
    variableUpdates[mapping.variable] = value;
  }
  return { ok: true, variable_updates: variableUpdates };
}

function errorResult(errorCode: string): WebhookExecutionResultV1 {
  return { ok: false, error_code: errorCode };
}

function renderRequest(
  node: Readonly<WebhookNodeV1>,
  variables: Readonly<Record<string, JsonValue>>,
) {
  const renderedUrl = renderChatbotTemplate(node.config.url, variables, 2048);
  if (!renderedUrl.ok) throw new Error(renderedUrl.code);

  const headers = new Headers();
  for (const header of node.config.headers) {
    const rendered = renderChatbotTemplate(header.value, variables, 4096);
    if (!rendered.ok) throw new Error(rendered.code);
    headers.set(header.name, rendered.text);
  }

  let body: string | undefined;
  if (node.config.body_template !== undefined) {
    const rendered = renderChatbotTemplate(
      node.config.body_template,
      variables,
      CHATBOT_WEBHOOK_BODY_MAX_LENGTH,
    );
    if (!rendered.ok) throw new Error(rendered.code);
    JSON.parse(rendered.text);
    body = rendered.text;
    headers.set("content-type", "application/json");
  }

  return { url: renderedUrl.text, headers, body };
}

export function createWebhookExecutor(
  dependencies: WebhookExecutorDependencies,
): WebhookExecutorV1 {
  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const resolveDns = dependencies.resolveDns ?? defaultResolveDns;

  return async (node, variables) => {
    let request: ReturnType<typeof renderRequest>;
    try {
      request = renderRequest(node, variables);
    } catch {
      return errorResult("webhook_template_invalid");
    }

    if (node.config.secret_id) {
      let secretHeaders: Readonly<Record<string, string>> | null;
      try {
        secretHeaders = await dependencies.resolveSecret(node.config.secret_id);
      } catch {
        return errorResult("webhook_secret_unavailable");
      }
      if (!secretHeaders) return errorResult("webhook_secret_unavailable");
      for (const [name, value] of Object.entries(secretHeaders)) {
        if (
          [
            "host",
            "content-length",
            "connection",
            "transfer-encoding",
            "upgrade",
            "proxy-authorization",
            "idempotency-key",
          ].includes(name.toLowerCase())
        ) {
          return errorResult("webhook_secret_header_blocked");
        }
        request.headers.set(name, value);
      }
    }
    request.headers.set("idempotency-key", dependencies.idempotencyKey);

    const attempts = node.config.retry_count + 1;
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        let currentUrl = await validateWebhookUrl(request.url, resolveDns);
        let redirects = 0;
        let response: Response;

        while (true) {
          response = await fetchImpl(currentUrl, {
            method: node.config.method,
            headers: request.headers,
            body: ["GET", "DELETE"].includes(node.config.method)
              ? undefined
              : request.body,
            redirect: "manual",
            signal: AbortSignal.timeout(node.config.timeout_ms),
          });

          if (
            [301, 302, 303, 307, 308].includes(response.status) &&
            response.headers.has("location")
          ) {
            if (redirects >= CHATBOT_WEBHOOK_MAX_REDIRECTS) {
              return errorResult("webhook_redirect_limit");
            }
            const nextUrl = await validateWebhookUrl(
              new URL(response.headers.get("location")!, currentUrl).toString(),
              resolveDns,
            );
            if (nextUrl.origin !== currentUrl.origin) {
              return errorResult("webhook_cross_origin_redirect");
            }
            currentUrl = nextUrl;
            redirects += 1;
            continue;
          }
          break;
        }

        const responseText = await readBoundedResponse(response);
        if (!response.ok) {
          if (
            attempt + 1 < attempts &&
            (response.status === 429 || response.status >= 500)
          ) {
            continue;
          }
          return {
            ok: false,
            status_code: response.status,
            error_code: "webhook_http_error",
          };
        }

        let responseBody: unknown = null;
        if (responseText) {
          try {
            responseBody = JSON.parse(responseText);
          } catch {
            return errorResult("webhook_response_not_json");
          }
        }

        const mapped = mapWebhookResponse(node, responseBody);
        if (!mapped.ok) return mapped;
        return {
          ok: true,
          status_code: response.status,
          variable_updates: mapped.variable_updates,
        };
      } catch (error) {
        if (attempt + 1 < attempts) continue;
        const isTimeout = error instanceof DOMException &&
          error.name === "TimeoutError";
        return errorResult(
          isTimeout ? "webhook_timeout" : "webhook_request_failed",
        );
      }
    }

    return errorResult("webhook_request_failed");
  };
}
