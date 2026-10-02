import { createUnsecureClient, type Json } from "../supabase.ts";
import {
  nodeBridgeConnection,
  nodeBridgePhaseId,
  nodeBridgeRequest,
} from "./node_bridge_client.ts";
import { conversationOperationError } from "./conversation_lifecycle.ts";

export async function processNodeBridgeOperation(requestId: string) {
  const client = createUnsecureClient();
  const { data: operation, error } = await client.from(
    "chatbot_node_operations",
  ).select().eq("request_id", requestId).single();
  if (error || !operation) throw new Error("Unable to load bridge operation");
  const conversationScoped = operation.conversation_id !== null;
  if (["succeeded", "failed"].includes(operation.status)) return operation;
  if (
    operation.next_attempt_at &&
    Date.parse(operation.next_attempt_at) > Date.now()
  ) return operation;
  const connection = nodeBridgeConnection(
    operation.organization_id,
    operation.organization_address,
  );
  const remoteId = await nodeBridgePhaseId(requestId, operation.phase);
  const payload = operation.payload as Record<string, Json | undefined>;
  let acknowledged: Record<string, Json> | undefined;
  const reconciling = operation.status === "in_flight" ||
    operation.status === "reconciling";
  if (reconciling) {
    try {
      const remote = await nodeBridgeRequest(
        connection,
        `bridge/operations/${remoteId}`,
      );
      if (remote.ok) acknowledged = (await remote.json()).data;
      else if (
        remote.status === 404
      ) {
        /* Confirmed absent: same request can be submitted. */
      } else throw new Error("Node reconciliation unavailable");
    } catch {
      if (!conversationScoped) {
        await client.from("chatbot_node_bridges").update({
          last_error: "Node status lookup unavailable; synchronization pending",
        })
          .eq("organization_id", operation.organization_id).eq(
            "organization_address",
            operation.organization_address,
          );
      }
      await client.from("chatbot_node_operations").update({
        status: "reconciling",
        last_error: "Node status lookup unavailable",
        next_attempt_at: new Date(Date.now() + 30_000).toISOString(),
      }).eq("request_id", requestId);
      return operation;
    }
  }
  if (!acknowledged) {
    if (operation.attempts >= 5) {
      await client.from("chatbot_node_operations").update({
        status: "failed",
        last_error: "Retry limit reached",
        next_attempt_at: null,
      }).eq("request_id", requestId);
      if (conversationScoped) {
        // Exhaustion is safe to release only after status lookup confirmed the
        // request absent. Unavailable/ambiguous status stays reconciling above.
        await client.from("chatbot_node_conversations").update({
          pending_request_id: null,
        })
          .eq("conversation_id", operation.conversation_id!).eq(
            "pending_request_id",
            requestId,
          );
      } else {await client.from("chatbot_node_bridges").update({
          sync_status: "failed",
          last_error: "Retry limit reached",
        })
          .eq("organization_id", operation.organization_id).eq(
            "organization_address",
            operation.organization_address,
          );}
      return {
        ...operation,
        status: "failed",
        last_error: "Retry limit reached",
      };
    }
    // CAS is the durable claim. A crashed in-flight request is reconciled by
    // the same phase request ID, never automatically rolled back or resubmitted.
    const { data: claimed, error: claimError } = await client.from(
      "chatbot_node_operations",
    ).update({
      status: "in_flight",
      attempts: operation.attempts + 1,
      next_attempt_at: new Date(Date.now() + 60_000).toISOString(),
    }).eq("request_id", requestId).eq("status", operation.status).eq(
      "attempts",
      operation.attempts,
    ).select().maybeSingle();
    if (claimError) throw new Error("Unable to claim bridge operation");
    if (!claimed) return operation;
    try {
      if (operation.phase === "prepare") {
        const secretKeys = payload.credential_keys as
          | Record<string, Record<string, string>>
          | undefined;
        for (
          const [credentialId, headers] of Object.entries(secretKeys ?? {})
        ) {
          const { data: values, error: secretError } = await client.rpc(
            "resolve_chatbot_webhook_credential",
            {
              p_organization_id: operation.organization_id,
              p_credential_id: credentialId,
            },
          );
          if (
            secretError || !values || typeof values !== "object"
          ) throw new Error("Protected credential unavailable");
          for (const [header, key] of Object.entries(headers)) {
            const value = (values as Record<string, Json>)[header];
            if (typeof value !== "string") {
              throw new Error(
                "Protected credential changed; reactivation required",
              );
            }
            const transferred = await nodeBridgeRequest(
              connection,
              `configuration/secrets/${key}`,
              "PUT",
              { value },
            );
            if (!transferred.ok) {
              throw new Error("Protected credential transfer failed");
            }
          }
        }
      }
      const body = operation.phase === "prepare"
        ? {
          action: "prepare",
          organization_id: operation.organization_id,
          phone_number_id: operation.organization_address,
          source_flow_id: payload.source_flow_id,
          source_version_id: payload.source_version_id,
          definition_hash: payload.definition_hash,
          graph: payload.graph,
        }
        : {
          action: operation.phase,
          organization_id: operation.organization_id,
          phone_number_id: operation.organization_address,
          ...(operation.phase === "activate"
            ? {
              flow_id: (operation.result as Record<string, Json>)?.flow_id,
              version_id: (operation.result as Record<string, Json>)
                ?.version_id,
            }
            : {}),
          ...(operation.phase === "resume" ||
              operation.phase === "resolve-and-close"
            ? {
              conversation_id: payload.node_conversation_id,
              ...(conversationScoped
                ? {
                  expected_revision: payload.expected_revision,
                  observed_last_inbound_wamid:
                    payload.observed_last_inbound_wamid,
                  client_request_id: requestId,
                }
                : {}),
            }
            : {}),
        };
      const remote = await nodeBridgeRequest(
        connection,
        `bridge/operations/${remoteId}`,
        "PUT",
        body,
      );
      if (!remote.ok) {
        if ([400, 401, 403, 404, 409, 422].includes(remote.status)) {
          const rejection = await remote.json().catch(() => ({}));
          const failure = conversationScoped
            ? conversationOperationError(rejection.message)
            : `Node rejected ${operation.phase} (HTTP ${remote.status})`;
          await client.from("chatbot_node_operations").update({
            status: "failed",
            last_error: failure,
            next_attempt_at: null,
          }).eq("request_id", requestId);
          if (conversationScoped) {
            await client.from("chatbot_node_conversations").update({
              pending_request_id: null,
            })
              .eq("conversation_id", operation.conversation_id!).eq(
                "pending_request_id",
                requestId,
              );
          } else {await client.from("chatbot_node_bridges").update({
              sync_status: "failed",
              last_error: `Node rejected operation (HTTP ${remote.status})`,
            })
              .eq("organization_id", operation.organization_id).eq(
                "organization_address",
                operation.organization_address,
              );}
          return { ...operation, status: "failed", last_error: failure };
        }
        throw new Error("Ambiguous Node response");
      }
      acknowledged = (await remote.json()).data;
      if (!acknowledged) throw new Error("Node acknowledgment missing");
    } catch {
      if (!conversationScoped) {
        await client.from("chatbot_node_bridges").update({
          last_error: "Node acknowledgment unavailable; reconciling request ID",
        })
          .eq("organization_id", operation.organization_id).eq(
            "organization_address",
            operation.organization_address,
          );
      }
      await client.from("chatbot_node_operations").update({
        status: "reconciling",
        last_error: "Node acknowledgment unavailable; reconciling request ID",
        next_attempt_at: new Date(Date.now() + 1000 * 2 ** operation.attempts)
          .toISOString(),
      }).eq("request_id", requestId);
      return operation;
    }
  }
  // RPC commits mapping and phase completion atomically. If it fails, leave
  // the durable in-flight request available for acknowledgment reconciliation.
  if (conversationScoped) {
    // The persisted operation result is immutable, but the customer may have
    // reopened/escalated since it committed. Apply current revision, not stale ACK.
    const current = await nodeBridgeRequest(
      connection,
      `bridge/conversations/${payload.node_conversation_id}`,
    );
    if (!current.ok) {
      throw new Error("Unable to reconcile current conversation ownership");
    }
    const snapshot = (await current.json()).data;
    if (
      !snapshot || !/^\d+$/.test(snapshot.revision) ||
      BigInt(snapshot.revision) < BigInt(String(acknowledged?.revision ?? "0"))
    ) {
      throw new Error("Invalid conversation reconciliation snapshot");
    }
    acknowledged = snapshot;
  }
  const { data, error: completionError } = await client.rpc(
    "complete_node_chatbot_operation",
    {
      p_request_id: requestId,
      p_phase: operation.phase,
      p_result: acknowledged as Json,
    },
  );
  if (completionError) {
    throw new Error("Unable to commit bridge acknowledgment");
  }
  if (data.phase === "activate" && data.status === "pending") {
    return await processNodeBridgeOperation(requestId);
  }
  return data;
}
