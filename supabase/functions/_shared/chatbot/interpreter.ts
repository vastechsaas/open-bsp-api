import type {
  ChatbotOutgoingMessageV1,
  ConditionOperatorV1,
  FlowDefinitionV1,
  FlowEdgeV1,
  JsonValue,
  NodeResultV1,
} from "./flow_definition.ts";
import { flowDefinitionV1Schema } from "./flow_definition.ts";
import { executeNodeStrategy } from "./strategies.ts";

export const CHATBOT_MAX_AUTOMATIC_TRANSITIONS = 50;

export interface InterpretFlowInputV1 {
  readonly current_node_id: string;
  readonly variables: Readonly<Record<string, JsonValue>>;
  readonly free_text_input?: string;
  readonly option_input?: {
    readonly kind: "button" | "list_selection";
    readonly id: string;
  };
}

export interface InterpretationErrorV1 {
  readonly code: string;
  readonly message: string;
  readonly details?: Readonly<Record<string, JsonValue>>;
}

export interface InterpretationResultV1 {
  readonly status: "waiting" | "completed" | "failed";
  readonly current_node_id: string;
  readonly waiting_for: "free_text" | "button" | "list_selection" | null;
  readonly variables: Readonly<Record<string, JsonValue>>;
  readonly outgoing_texts: readonly string[];
  readonly outgoing_messages: readonly ChatbotOutgoingMessageV1[];
  readonly error: InterpretationErrorV1 | null;
  readonly transition_count: number;
}

function normalizeOperand(value: string): string {
  return value.trim().toLowerCase();
}

export function conditionMatchesV1(
  operator: ConditionOperatorV1,
  actual: string,
  expected: string,
): boolean {
  const normalizedActual = normalizeOperand(actual);
  const normalizedExpected = normalizeOperand(expected);

  switch (operator) {
    case "equals":
      return normalizedActual === normalizedExpected;
    case "not_equals":
      return normalizedActual !== normalizedExpected;
    case "contains":
      return normalizedActual.includes(normalizedExpected);
    case "starts_with":
      return normalizedActual.startsWith(normalizedExpected);
    case "ends_with":
      return normalizedActual.endsWith(normalizedExpected);
  }
}

function failedResult(
  currentNodeId: string,
  variables: Readonly<Record<string, JsonValue>>,
  outgoingTexts: readonly string[],
  outgoingMessages: readonly ChatbotOutgoingMessageV1[],
  transitionCount: number,
  error: InterpretationErrorV1,
): InterpretationResultV1 {
  return {
    status: "failed",
    current_node_id: currentNodeId,
    waiting_for: null,
    variables,
    outgoing_texts: outgoingTexts,
    outgoing_messages: outgoingMessages,
    error,
    transition_count: transitionCount,
  };
}

function resolveTarget(
  definition: FlowDefinitionV1,
  sourceNodeId: string,
  route: Extract<NodeResultV1, { type: "advance" }>["route"] | {
    kind: "default";
  },
): string | undefined {
  const sourceEdges = definition.edges.filter((edge) =>
    edge.source === sourceNodeId
  );

  if (route.kind === "default") {
    return sourceEdges.find((edge) => edge.kind === "default")?.target;
  }

  if (route.kind === "option") {
    return sourceEdges.find((edge) =>
      edge.kind === "option" && edge.option_id === route.option_id
    )?.target;
  }

  const matchedEdge = sourceEdges.find((edge): edge is Extract<
    FlowEdgeV1,
    { kind: "condition" }
  > =>
    edge.kind === "condition" &&
    conditionMatchesV1(edge.operator, route.value, edge.value)
  );

  return matchedEdge?.target ??
    sourceEdges.find((edge) => edge.kind === "default")?.target;
}

export async function interpretFlowDefinitionV1(
  storedDefinition: unknown,
  input: InterpretFlowInputV1,
): Promise<InterpretationResultV1> {
  const parsedDefinition = flowDefinitionV1Schema.safeParse(storedDefinition);
  const variables: Record<string, JsonValue> = { ...input.variables };
  const outgoingTexts: string[] = [];
  const outgoingMessages: ChatbotOutgoingMessageV1[] = [];

  if (!parsedDefinition.success) {
    return failedResult(
      input.current_node_id,
      variables,
      outgoingTexts,
      outgoingMessages,
      0,
      {
        code: "invalid_definition",
        message: "Stored chatbot flow definition is invalid",
        details: { issue_count: parsedDefinition.error.issues.length },
      },
    );
  }

  const definition = parsedDefinition.data;
  const nodesById = new Map(definition.nodes.map((node) => [node.id, node]));
  let currentNodeId = input.current_node_id;
  let transitionCount = 0;
  let inputConsumed = false;

  while (transitionCount < CHATBOT_MAX_AUTOMATIC_TRANSITIONS) {
    const node = nodesById.get(currentNodeId);

    if (!node) {
      return failedResult(
        currentNodeId,
        variables,
        outgoingTexts,
        outgoingMessages,
        transitionCount,
        {
          code: "node_not_found",
          message: `Chatbot node ${currentNodeId} was not found`,
          details: { node_id: currentNodeId },
        },
      );
    }

    const offersInput = node.type === "collect_input" &&
      !inputConsumed && input.free_text_input !== undefined;
    const offersOptionInput =
      (node.type === "interactive_buttons" || node.type === "list_message") &&
      !inputConsumed && input.option_input !== undefined;
    const result = await executeNodeStrategy(node, {
      variables,
      free_text_input: offersInput ? input.free_text_input : undefined,
      option_input: offersOptionInput ? input.option_input : undefined,
    });

    if (offersInput || offersOptionInput) {
      inputConsumed = true;
    }

    transitionCount += 1;

    if (result.type === "fail") {
      return failedResult(
        currentNodeId,
        variables,
        outgoingTexts,
        outgoingMessages,
        transitionCount,
        {
          code: result.code,
          message: result.message,
          details: result.details,
        },
      );
    }

    if (result.type === "complete") {
      return {
        status: "completed",
        current_node_id: currentNodeId,
        waiting_for: null,
        variables,
        outgoing_texts: outgoingTexts,
        outgoing_messages: outgoingMessages,
        error: null,
        transition_count: transitionCount,
      };
    }

    if (result.type === "wait_for_input") {
      if (result.prompt) {
        outgoingTexts.push(result.prompt);
        outgoingMessages.push({ type: "text", text: result.prompt });
      }
      if (result.message) {
        outgoingMessages.push(result.message);
      }
      return {
        status: "waiting",
        current_node_id: currentNodeId,
        waiting_for: result.expectation.kind,
        variables,
        outgoing_texts: outgoingTexts,
        outgoing_messages: outgoingMessages,
        error: null,
        transition_count: transitionCount,
      };
    }

    if (result.type === "emit_message") {
      outgoingMessages.push(result.message);
      if (result.message.type === "text") {
        outgoingTexts.push(result.message.text);
      }
    }

    if (result.type === "advance" && result.variable_updates) {
      Object.assign(variables, result.variable_updates);
    }

    const targetNodeId = resolveTarget(definition, currentNodeId, result.route);

    if (!targetNodeId) {
      return failedResult(
        currentNodeId,
        variables,
        outgoingTexts,
        outgoingMessages,
        transitionCount,
        {
          code: "missing_route",
          message: `Chatbot node ${currentNodeId} has no matching route`,
          details: { node_id: currentNodeId },
        },
      );
    }

    currentNodeId = targetNodeId;
  }

  return failedResult(
    currentNodeId,
    variables,
    outgoingTexts,
    outgoingMessages,
    transitionCount,
    {
      code: "transition_limit_exceeded",
      message:
        `Chatbot execution exceeded ${CHATBOT_MAX_AUTOMATIC_TRANSITIONS} transitions`,
      details: { max_transitions: CHATBOT_MAX_AUTOMATIC_TRANSITIONS },
    },
  );
}
