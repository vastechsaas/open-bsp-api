import {
  compileFlowDefinition,
  interpretFlowDefinitionV1,
  type JsonValue,
} from "../_shared/chatbot/mod.ts";
import type { EditorGraph } from "./payload.ts";

export type ChatbotSimulationInput = {
  current_node_id?: string;
  variables: Record<string, unknown>;
  free_text_input?: string;
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
  });

  return {
    valid: true as const,
    ...result,
  };
}
