import {
  compileFlowDefinition,
  interpretFlowDefinitionV1,
  type JsonValue,
  mapWebhookResponse,
} from "../_shared/chatbot/mod.ts";
import type { EditorGraph } from "./payload.ts";

export type ChatbotSimulationInput = {
  current_node_id?: string;
  variables: Record<string, unknown>;
  free_text_input?: string;
  option_input?: {
    kind: "button" | "list_selection";
    id: string;
  };
  webhook_mocks?: Record<
    string,
    { outcome: "success" | "error"; status_code: number; body: unknown }
  >;
};

export async function simulateChatbotFlow(
  editorGraph: EditorGraph,
  input: ChatbotSimulationInput,
) {
  const compiled = compileFlowDefinition(editorGraph);
  if (!compiled.ok) {
    return {
      valid: false as const,
      issues: compiled.issues,
    };
  }

  const result = await interpretFlowDefinitionV1(compiled.definition, {
    current_node_id: input.current_node_id ?? compiled.definition.start_node_id,
    variables: input.variables as Record<string, JsonValue>,
    ...(input.free_text_input === undefined
      ? {}
      : { free_text_input: input.free_text_input }),
    ...(input.option_input === undefined
      ? {}
      : { option_input: input.option_input }),
    webhook_executor: (node) => {
      const mock = input.webhook_mocks?.[node.id] ?? {
        outcome: "success" as const,
        status_code: 200,
        body: {},
      };
      if (mock.outcome === "error") {
        return Promise.resolve({
          ok: false,
          status_code: mock.status_code,
          error_code: "simulated_webhook_error",
        });
      }
      return Promise.resolve({
        ...mapWebhookResponse(node, mock.body),
        status_code: mock.status_code,
      });
    },
  });

  return {
    valid: true as const,
    ...result,
  };
}
