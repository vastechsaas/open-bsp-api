import type { AccountConfig, IntegrationEvent } from "./contracts.js";
import type { Logger } from "./logger.js";

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
};

const retryDelays = [1_000, 5_000];

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
    url: `${functionsBaseUrl}/chatbot-reply-webhook`,
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

function isRetriableStatus(status: number) {
  return status === 429 || status >= 500;
}

function errorReason(error: unknown) {
  if (error instanceof DOMException && error.name === "TimeoutError") {
    return "request timeout";
  }
  return error instanceof Error ? error.name : "network error";
}

export function createForwarder(options: ForwarderOptions) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const sleep = options.sleep ??
    ((milliseconds: number) =>
      new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
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

    for (let attempt = 1; attempt <= 3; attempt += 1) {
      const startedAt = Date.now();
      try {
        const response = await fetchImpl(request.url, {
          ...request.init,
          signal: AbortSignal.timeout(timeoutMs),
        });
        options.logger.info("Edge Function request completed", {
          event_id: event.event_id,
          event_type: event.event_type,
          integration_key: event.integration_key,
          attempt,
          duration_ms: Date.now() - startedAt,
          response_status: response.status,
        });

        if (response.ok) {
          return {
            outcome: "success",
            status: response.status,
            attempts: attempt,
          };
        }
        if (!isRetriableStatus(response.status)) {
          return {
            outcome: "permanent_failure",
            status: response.status,
            reason: `Edge Function returned HTTP ${response.status}`,
            attempts: attempt,
          };
        }

        if (attempt === 3) {
          return {
            outcome: "permanent_failure",
            status: response.status,
            reason: "transient Edge Function failure exhausted retries",
            attempts: attempt,
          };
        }
      } catch (error) {
        options.logger.warn("Edge Function request failed", {
          event_id: event.event_id,
          event_type: event.event_type,
          integration_key: event.integration_key,
          attempt,
          duration_ms: Date.now() - startedAt,
          error: errorReason(error),
        });
        if (attempt === 3) {
          return {
            outcome: "permanent_failure",
            reason: "network failure exhausted retries",
            attempts: attempt,
          };
        }
      }

      await sleep(retryDelays[attempt - 1] ?? retryDelays.at(-1)!);
    }

    throw new Error("unreachable retry state");
  };
}
