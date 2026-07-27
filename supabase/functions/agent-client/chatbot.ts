import type { SupabaseClient } from "@supabase/supabase-js";
import {
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
      p_outgoing_texts: [...interpreted.outgoing_texts],
    },
  );

  if (commitError) throw commitError;

  const committed = committedRows[0];
  return {
    handled: true,
    outcome: committed?.outcome === "committed" ? "committed" : "conflict",
  };
}

export const chatbotRuntimeTestables = { freeTextInput };
