import { z } from "zod";

const connectionSchema = z.object({
  url: z.string().url().refine((value) => {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password &&
      !url.search && !url.hash;
  }, "Node URL must be HTTPS without credentials/query/fragment"),
  company_id: z.string().regex(/^\d+$/),
  credential: z.string().min(32),
}).strict();

export function nodeBridgeConnection(organizationId: string, address: string) {
  if (Deno.env.get("NODE_CHATBOT_BRIDGE_ENABLED") !== "true") {
    throw new Error("Node bridge is disabled");
  }
  const connections = z.record(z.string(), connectionSchema).parse(
    JSON.parse(Deno.env.get("NODE_CHATBOT_CONNECTIONS") ?? "{}"),
  );
  const connection = connections[`${organizationId}:${address}`];
  if (!connection) {
    throw new Error("Node connection is not configured for this tenant/number");
  }
  return connection;
}

export async function nodeBridgeRequest(
  connection: ReturnType<typeof nodeBridgeConnection>,
  path: string,
  method = "GET",
  body?: unknown,
) {
  return await fetch(`${connection.url.replace(/\/$/, "")}/api/v1/${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${connection.credential}`,
      "x-tenant-id": connection.company_id,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
    redirect: "error",
  });
}

export async function nodeBridgePhaseId(requestId: string, phase: string) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`${requestId}:${phase}`),
    ),
  ).slice(0, 16);
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20)}`;
}
