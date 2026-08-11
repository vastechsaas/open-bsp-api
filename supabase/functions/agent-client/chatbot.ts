import type { SupabaseClient } from "@supabase/supabase-js";
import {
  createWebhookExecutor,
  interpretFlowDefinitionV1,
  type JsonValue,
} from "../_shared/chatbot/mod.ts";
import type { Database, Json, MessageRow } from "../_shared/supabase.ts";

export type ChatbotMessageOutcome =
  | "not_started"
  | "duplicate"
  | "stale"
  | "committed"
  | "conflict";

export interface ChatbotMessageResult {
  handled: boolean;
  outcome: ChatbotMessageOutcome;
}

function freeTextInput(
  incoming: MessageRow,
  runIsNew: boolean,
  runStatus: string | null,
): string | undefined {
  if (
    runIsNew ||
    runStatus !== "waiting" ||
    incoming.content.type !== "text"
  ) {
    return undefined;
  }

  return incoming.content.text;
}

function optionInput(
  incoming: MessageRow,
  runIsNew: boolean,
  runStatus: string | null,
  runWaitingFor: string | null,
) {
  if (
    runIsNew ||
    runStatus !== "waiting" ||
    incoming.content.kind !== "interactive"
  ) {
    return undefined;
  }

  const interactive = incoming.content.data;
  if (
    runWaitingFor === "button" &&
    interactive.type === "button_reply"
  ) {
    return { kind: "button" as const, id: interactive.button_reply.id };
  }
  if (
    runWaitingFor === "list_selection" &&
    interactive.type === "list_reply"
  ) {
    return {
      kind: "list_selection" as const,
      id: interactive.list_reply.id,
    };
  }

  return undefined;
}

export async function processChatbotMessage(
  client: SupabaseClient<Database>,
  incoming: MessageRow,
): Promise<ChatbotMessageResult> {
  const { data: deployment, error: deploymentError } = await client
    .from("chatbot_flow_deployments")
    .select("flow_version_id, agent_id")
    .eq("organization_id", incoming.organization_id)
    .eq("organization_address", incoming.organization_address)
    .maybeSingle();

  if (deploymentError) throw deploymentError;

  const { data: preparedRows, error: prepareError } = await client.rpc(
    "prepare_chatbot_flow_execution",
    {
      p_message_id: incoming.id,
      ...(deployment
        ? {
          p_flow_version_id: deployment.flow_version_id,
          p_agent_id: deployment.agent_id,
        }
        : {}),
    },
  );

  if (prepareError) throw prepareError;

  const prepared = preparedRows[0];
  if (!prepared || prepared.outcome === "not_started") {
    return { handled: false, outcome: "not_started" };
  }
  if (prepared.outcome === "duplicate" || prepared.outcome === "stale") {
    return { handled: true, outcome: prepared.outcome };
  }
  if (
    prepared.outcome !== "ready" ||
    !prepared.run_id ||
    prepared.run_lock_version === null ||
    !prepared.run_current_node_id ||
    !prepared.flow_definition
  ) {
    throw new Error("Chatbot execution preparation returned an invalid state");
  }

  const interpreted = await interpretFlowDefinitionV1(
    prepared.flow_definition,
    {
      current_node_id: prepared.run_current_node_id,
      variables: (prepared.run_variables ?? {}) as Record<string, JsonValue>,
      free_text_input: freeTextInput(
        incoming,
        prepared.run_is_new,
        prepared.run_status,
      ),
      option_input: optionInput(
        incoming,
        prepared.run_is_new,
        prepared.run_status,
        prepared.run_waiting_for,
      ),
      webhook_executor: createWebhookExecutor({
        idempotencyKey:
          `chatbot:${prepared.run_id}:${incoming.id}:${prepared.run_lock_version}`,
        resolveSecret: async (secretId) => {
          const { data, error } = await client.rpc(
            "resolve_chatbot_webhook_credential",
            {
              p_organization_id: incoming.organization_id,
              p_credential_id: secretId,
            },
          );
          if (
            error || !data || typeof data !== "object" || Array.isArray(data)
          ) {
            return null;
          }
          const entries = Object.entries(data);
          return entries.every(([, value]) => typeof value === "string")
            ? Object.fromEntries(entries) as Record<string, string>
            : null;
        },
      }),
    },
  );

  const { data: committedRows, error: commitError } = await client.rpc(
    "commit_chatbot_flow_execution",
    {
      p_run_id: prepared.run_id,
      p_expected_lock_version: prepared.run_lock_version,
      p_message_id: incoming.id,
      p_current_node_id: interpreted.current_node_id,
      p_status: interpreted.status,
      // Postgres accepts NULL here, but generated RPC argument types do not
      // preserve parameter nullability.
      p_waiting_for: interpreted.waiting_for as string,
      p_variables: interpreted.variables as Json,
      p_error: interpreted.error as Json | null,
      p_outgoing_texts: [],
      p_outgoing_messages: [
        ...interpreted.outgoing_messages,
      ] as unknown as Json,
      ...(interpreted.handoff_agent_id
        ? { p_handoff_agent_id: interpreted.handoff_agent_id }
        : {}),
      ...(interpreted.handoff_routing_queue_id
        ? {
          p_handoff_routing_queue_id: interpreted.handoff_routing_queue_id,
        }
        : {}),
    },
  );

  if (commitError) throw commitError;

  const committed = committedRows[0];
  return {
    handled: true,
    outcome: committed?.outcome === "committed" ? "committed" : "conflict",
  };
}

export const chatbotRuntimeTestables = { freeTextInput, optionInput };
