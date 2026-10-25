import { z } from "zod";
import { createUnsecureClient } from "../supabase.ts";
import {
  nodeBridgeConnection,
  nodeBridgePhaseId,
  nodeBridgeRequest,
} from "./node_bridge_client.ts";
import { boundedWork } from "./bounded_work.ts";

const snapshotSchema = z.object({
  organization_id: z.uuid(),
  phone_number_id: z.string().regex(/^\d+$/),
  account_revision: z.string().regex(/^[1-9]\d*$/),
  connected: z.boolean(),
  access_token: z.string().nullable(),
  token_expires_at: z.string().nullable(),
  application_id: z.string().nullable(),
  waba_id: z.string().nullable(),
});

export class AccountAuthenticationError extends Error {
  constructor() {
    super("WhatsApp reconnection required");
  }
}

// Read-only validation. Never log/return raw Graph requests or token responses.
export async function verifyWhatsAppAccountToken(
  token: string,
  appId: string | null,
  phoneId: string,
  signal?: AbortSignal,
) {
  const ids = (Deno.env.get("META_APP_ID") ?? "").split("|");
  const secrets = (Deno.env.get("META_APP_SECRET") ?? "").split("|");
  const index = appId ? ids.indexOf(appId) : ids.length === 1 ? 0 : -1;
  if (index < 0 || !ids[index] || !secrets[index]) {
    throw new Error("Matching Meta app is not configured");
  }
  const url = new URL("https://graph.facebook.com/v24.0/debug_token");
  url.searchParams.set("input_token", token);
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${ids[index]}|${secrets[index]}` },
    signal: signal
      ? AbortSignal.any([signal, AbortSignal.timeout(10_000)])
      : AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error("Meta token inspection unavailable");
  if (body.data?.is_valid === false) throw new AccountAuthenticationError();
  if (body.data?.is_valid !== true) {
    throw new Error("Meta token inspection unavailable");
  }
  if (String(body.data.app_id) !== ids[index]) {
    throw new Error("Token belongs to a different Meta app");
  }
  const expires = body.data.expires_at;
  if (!Number.isSafeInteger(expires) || expires < 0) {
    throw new Error("Meta token expiry is unavailable");
  }
  if (expires && expires * 1000 <= Date.now()) {
    throw new AccountAuthenticationError();
  }
  const permissions = new Set(body.data.scopes ?? []);
  if (
    !permissions.has("whatsapp_business_messaging") ||
    !permissions.has("whatsapp_business_management")
  ) {
    throw new Error("Required WhatsApp permissions are missing");
  }
  const phone = await fetch(
    `https://graph.facebook.com/v24.0/${phoneId}?fields=id`,
    {
      headers: { Authorization: `Bearer ${token}` },
      signal: signal
        ? AbortSignal.any([signal, AbortSignal.timeout(10_000)])
        : AbortSignal.timeout(10_000),
    },
  );
  const phoneBody = await phone.json().catch(() => ({}));
  if (!phone.ok) {
    if (phone.status === 401 || phoneBody.error?.code === 190) {
      throw new AccountAuthenticationError();
    }
    throw new Error("WhatsApp number verification unavailable");
  }
  if (String(phoneBody.id) !== phoneId) {
    throw new Error("WhatsApp number verification failed");
  }
  return expires ? new Date(expires * 1000).toISOString() : null;
}

export async function processWhatsAppAccountSync(
  requestId: string,
  signal?: AbortSignal,
) {
  if (Deno.env.get("NODE_WHATSAPP_ACCOUNT_SYNC_ENABLED") !== "true") return;
  const client = createUnsecureClient();
  const { data: op, error } = await client.from("chatbot_node_operations")
    .select().eq("request_id", requestId).single();
  if (error || !op || ["failed", "succeeded"].includes(op.status)) return;
  if (op.next_attempt_at && Date.parse(op.next_attempt_at) > Date.now()) return;
  const connection = nodeBridgeConnection(
    op.organization_id,
    op.organization_address,
  );
  const remoteId = await nodeBridgePhaseId(requestId, "account-sync");
  const { data: raw, error: resolveError } = await client.rpc(
    "resolve_whatsapp_account_sync",
    { p_request_id: requestId },
  );
  if (resolveError) {
    throw new Error("Account synchronization source unavailable");
  }
  if (!raw) {
    await client.from("chatbot_node_operations").update({
      status: "failed",
      last_error: "Superseded account revision",
    }).eq("request_id", requestId);
    return;
  }
  const source = snapshotSchema.parse(raw);
  try {
    let acknowledged: { account_revision?: string } | undefined;
    if (["in_flight", "reconciling"].includes(op.status)) {
      const status = await nodeBridgeRequest(
        connection,
        `bridge/operations/${remoteId}`,
        "GET",
        undefined,
        signal,
      );
      if (status.ok) acknowledged = (await status.json()).data;
      else if (status.status !== 404) {
        throw new Error("Account synchronization acknowledgment unavailable");
      }
    }
    if (!acknowledged) {
      if (op.attempts >= 5) {
        await client.from("chatbot_node_operations").update({
          status: "failed",
          next_attempt_at: null,
          last_error: "Account synchronization retry limit reached",
        }).eq("request_id", requestId);
        await client.from("chatbot_node_bridges").update({
          account_sync_status: "failed",
          account_last_error: "Account synchronization retry limit reached",
        })
          .eq("organization_id", op.organization_id).eq(
            "organization_address",
            op.organization_address,
          ).eq("account_revision", Number(source.account_revision));
        return;
      }
      const { data: claimed, error: claimError } = await client.from(
        "chatbot_node_operations",
      ).update({
        status: "in_flight",
        attempts: op.attempts + 1,
        next_attempt_at: new Date(Date.now() + 60_000).toISOString(),
      }).eq("request_id", requestId).eq("status", op.status).eq(
        "attempts",
        op.attempts,
      ).select().maybeSingle();
      if (claimError || !claimed) return;
      const capabilities = await nodeBridgeRequest(
        connection,
        "bridge/capabilities",
        "GET",
        undefined,
        signal,
      );
      if (
        !capabilities.ok ||
        !(await capabilities.json()).capabilities?.includes(
          "openbsp-account-sync-v1",
        )
      ) {
        throw new Error("Compatible Node deployment required");
      }
      let expiry = source.token_expires_at;
      if (source.connected) {
        if (!source.access_token) throw new AccountAuthenticationError();
        expiry = await verifyWhatsAppAccountToken(
          source.access_token,
          source.application_id,
          source.phone_number_id,
          signal,
        );
        // CAS prevents a delayed validation from changing a replacement token.
        if (expiry !== source.token_expires_at) {
          await client.from("organizations_addresses").update({
            extra: { token_expires_at: expiry },
          })
            .eq("organization_id", op.organization_id).eq(
              "address",
              op.organization_address,
            ).eq("service", "whatsapp")
            .eq("status", "connected").eq(
              "extra->>access_token",
              source.access_token,
            ).throwOnError();
        }
      }
      // Recheck revision after validation/metadata writes, before sending secrets.
      const { data: current } = await client.rpc(
        "resolve_whatsapp_account_sync",
        { p_request_id: requestId },
      );
      if (!current) return;
      await client.from("chatbot_node_bridges").update({
        account_sync_status: "syncing",
        account_last_error: null,
      })
        .eq("organization_id", op.organization_id).eq(
          "organization_address",
          op.organization_address,
        ).eq("account_revision", Number(source.account_revision));
      const remote = await nodeBridgeRequest(
        connection,
        `bridge/operations/${remoteId}`,
        "PUT",
        {
          action: "account-sync",
          organization_id: source.organization_id,
          phone_number_id: source.phone_number_id,
          waba_id: source.waba_id,
          account_revision: source.account_revision,
          connected: source.connected,
          access_token: source.connected ? source.access_token : null,
          token_expires_at: expiry,
        },
        signal,
      );
      if (!remote.ok) {
        throw new Error("Node account synchronization was not confirmed");
      }
      acknowledged = (await remote.json()).data;
    }
    if (acknowledged?.account_revision !== source.account_revision) {
      throw new Error("Account revision acknowledgment mismatch");
    }
    const { error: finishError } = await client.rpc(
      "complete_whatsapp_account_sync",
      { p_request_id: requestId, p_revision: source.account_revision },
    );
    if (finishError) {
      throw new Error("Account acknowledgment persistence failed");
    }
  } catch (error) {
    if (
      error instanceof AccountAuthenticationError && source.connected &&
      source.access_token
    ) {
      await client.from("organizations_addresses").update({
        status: "disconnected",
      }).eq("organization_id", op.organization_id)
        .eq("address", op.organization_address).eq("service", "whatsapp").eq(
          "status",
          "connected",
        )
        .eq("extra->>access_token", source.access_token).throwOnError();
    }
    // Do not log exceptions: fetch/validation errors can contain credentials.
    await client.from("chatbot_node_operations").update({
      status: "reconciling",
      last_error: "Account synchronization pending; retrying safely",
      next_attempt_at: new Date(
        Date.now() + Math.min(60_000, 1000 * 2 ** op.attempts),
      ).toISOString(),
    })
      .eq("request_id", requestId).neq("status", "failed");
    await client.from("chatbot_node_bridges").update({
      account_last_error:
        "Account synchronization pending; Node confirmation unavailable",
    })
      .eq("organization_id", op.organization_id).eq(
        "organization_address",
        op.organization_address,
      ).eq("account_revision", Number(source.account_revision));
  }
}

export async function reconcileWhatsAppAccounts() {
  if (Deno.env.get("NODE_WHATSAPP_ACCOUNT_SYNC_ENABLED") !== "true") return;
  const client = createUnsecureClient();
  const { data: bridges } = await client.from("chatbot_node_bridges").select(
    "organization_id,organization_address,account_revision,account_sync_status",
  )
    .neq("engine", "native").order("account_checked_at", { nullsFirst: true })
    .limit(5);
  await boundedWork(
    bridges ?? [],
    async (bridge, signal) => {
      try {
        if (
          bridge.account_revision === 0 ||
          bridge.account_sync_status === "pending"
        ) {
          await client.rpc("enqueue_whatsapp_account_sync", {
            p_organization_id: bridge.organization_id,
            p_address: bridge.organization_address,
          });
        }
        const connection = nodeBridgeConnection(
          bridge.organization_id,
          bridge.organization_address,
        );
        const remote = await nodeBridgeRequest(
          connection,
          "bridge/account",
          "GET",
          undefined,
          signal,
        );
        if (remote.ok) {
          const { data } = await remote.json();
          if (
            typeof data?.account_revision === "string" &&
            /^\d+$/.test(data.account_revision) &&
            bridge.account_sync_status === "synchronized" &&
            BigInt(data.account_revision) < BigInt(bridge.account_revision)
          ) {
            await client.rpc("enqueue_whatsapp_account_sync", {
              p_organization_id: bridge.organization_id,
              p_address: bridge.organization_address,
              p_force: true,
            });
          }
          if (data?.last_error === "META_AUTHENTICATION_FAILED") {
            await client.rpc("record_node_account_auth_failure", {
              p_organization_id: bridge.organization_id,
              p_address: bridge.organization_address,
              p_revision: data.account_revision,
            });
          }
        }
      } catch {
        /* One unreachable number must not block unrelated accounts. */
      }
      await client.from("chatbot_node_bridges").update({
        account_checked_at: new Date().toISOString(),
      })
        .eq("organization_id", bridge.organization_id).eq(
          "organization_address",
          bridge.organization_address,
        );
    },
    8000,
    3,
  );
}
