import type { AccountConfig, IntegrationEvent } from "./contracts.js";
import type { Logger } from "./logger.js";
import { eventLane } from "./routing.js";

export type ForwardResult =
  | { outcome: "success"; status: number; attempts: number }
  | {
    outcome: "permanent_failure";
    status?: number;
    reason: string;
    attempts: number;
  };

export type ForwarderOptions = {
  functionsBaseUrl: string;
  accounts: Record<string, AccountConfig>;
  logger: Logger;
  fetchImpl?: typeof fetch;
  sleep?: (milliseconds: number) => Promise<void>;
  timeoutMs?: number;
  edgeRegion?: string;
  signal?: AbortSignal;
};

function resolveRequest(
  event: IntegrationEvent,
  account: AccountConfig,
  functionsBaseUrl: string,
): { url: string; init: RequestInit } | { error: string } {
  if (event.event_type === "whatsapp_webhook") {
    if (event.payload.app_id !== account.meta_app_id) {
      return { error: "event app_id does not match integration configuration" };
    }
    return {
      url: `${functionsBaseUrl}/whatsapp-webhook?app_id=${
        encodeURIComponent(account.meta_app_id)
      }`,
      init: {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Hub-Signature-256": event.payload.x_hub_signature_256,
          "X-OpenBSP-Event-ID": event.event_id,
          ...(eventLane(event) === "statuses"
            ? {
              Authorization: `Bearer ${account.openbsp_api_key}`,
              "X-OpenBSP-Status-Only": "1",
            }
            : {}),
          ...(event.payload.node_messages
            ? {
              Authorization: `Bearer ${account.openbsp_api_key}`,
              "X-OpenBSP-Node-Messages": JSON.stringify(
                event.payload.node_messages,
              ),
            }
            : {}),
        },
        body: event.payload.raw_body,
      },
    };
  }

  if (event.payload.phone_number_id !== account.phone_number_id) {
    return {
      error: "event phone_number_id does not match integration configuration",
    };
  }

  return {
    url: `${functionsBaseUrl}/${
      event.event_type === "chatbot_conversation_lifecycle"
        ? "chatbot-conversation-lifecycle-webhook"
        : event.event_type === "chatbot_handoff"
        ? "chatbot-handoff-webhook"
        : "chatbot-reply-webhook"
    }`,
    init: {
      method: "POST",
      headers: {
        Authorization: `Bearer ${account.openbsp_api_key}`,
        "Content-Type": "application/json",
        "X-OpenBSP-Event-ID": event.event_id,
      },
      body: JSON.stringify({
        ...event.payload,
        chatbot: account.chatbot,
      }),
    },
  };
}

function errorReason(error: unknown) {
  if (error instanceof DOMException && error.name === "TimeoutError") {
    return "request timeout";
  }
  return error instanceof Error ? error.name : "network error";
}

export function createForwarder(options: ForwarderOptions) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;

  return async (event: IntegrationEvent): Promise<ForwardResult> => {
    const account = options.accounts[event.integration_key];
    if (!account) {
      return {
        outcome: "permanent_failure",
        reason: "unknown integration_key",
        attempts: 0,
      };
    }

    const request = resolveRequest(event, account, options.functionsBaseUrl);
    if ("error" in request) {
      return {
        outcome: "permanent_failure",
        reason: request.error,
        attempts: 0,
      };
    }

    // Retry scheduling belongs to durable RabbitMQ lanes, never this HTTP slot.
    const attempt = 1;
    const startedAt = Date.now();
    try {
      const response = await fetchImpl(request.url, {
        ...request.init,
        headers: {
          ...request.init.headers,
          ...(options.edgeRegion ? { "x-region": options.edgeRegion } : {}),
        },
        signal: options.signal
          ? AbortSignal.any([options.signal, AbortSignal.timeout(timeoutMs)])
          : AbortSignal.timeout(timeoutMs),
      });
      options.logger.info("Edge Function request completed", {
        event_id: event.event_id,
        event_type: event.event_type,
        integration_key: event.integration_key,
        attempt,
        duration_ms: Date.now() - startedAt,
        response_status: response.status,
        edge_region: response.headers.get("x-sb-edge-region"),
      });

      if (response.ok) {
        return {
          outcome: "success",
          status: response.status,
          attempts: attempt,
        };
      }
      return {
        outcome: "permanent_failure",
        status: response.status,
        reason: `Edge Function returned HTTP ${response.status}`,
        attempts: attempt,
      };
    } catch (error) {
      options.logger.warn("Edge Function request failed", {
        event_id: event.event_id,
        event_type: event.event_type,
        integration_key: event.integration_key,
        attempt,
        duration_ms: Date.now() - startedAt,
        error: errorReason(error),
      });
      return {
        outcome: "permanent_failure",
        reason: "network request failed; durable retry required",
        attempts: attempt,
      };
    }
  };
}
