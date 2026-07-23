import type {
  CollectInputNodeV1,
  ConditionNodeV1,
  EndNodeV1,
  ExecutionContextV1,
  FlowNodeV1,
  NodeResultV1,
  NodeStrategy,
  SendMessageNodeV1,
  StartNodeV1,
} from "./flow_definition.ts";

const defaultRoute = { kind: "default" } as const;

function waitForInput(node: Readonly<CollectInputNodeV1>): NodeResultV1 {
  return {
    type: "wait_for_input",
    prompt: node.config.prompt,
    expectation: {
      kind: "free_text",
      variable: node.config.variable,
      required: node.config.required,
      min_length: node.config.min_length,
      max_length: node.config.max_length,
    },
  };
}

export const startNodeStrategy: NodeStrategy<StartNodeV1> = {
  execute(): Promise<NodeResultV1> {
    return Promise.resolve({ type: "advance", route: defaultRoute });
  },
};

export const sendMessageNodeStrategy: NodeStrategy<SendMessageNodeV1> = {
  execute(node): Promise<NodeResultV1> {
    return Promise.resolve({
      type: "emit_message",
      message: { type: "text", text: node.config.text },
      route: defaultRoute,
    });
  },
};

export const collectInputNodeStrategy: NodeStrategy<CollectInputNodeV1> = {
  execute(node, context): Promise<NodeResultV1> {
    if (context.free_text_input === undefined) {
      return Promise.resolve(waitForInput(node));
    }

    const value = context.free_text_input.trim();
    const isEmpty = value.length === 0;
    const isTooShort = !isEmpty && node.config.min_length !== undefined &&
      value.length < node.config.min_length;
    const isTooLong = node.config.max_length !== undefined &&
      value.length > node.config.max_length;

    if ((node.config.required && isEmpty) || isTooShort || isTooLong) {
      return Promise.resolve(waitForInput(node));
    }

    return Promise.resolve({
      type: "advance",
      route: defaultRoute,
      variable_updates: { [node.config.variable]: value },
    });
  },
};

export const conditionNodeStrategy: NodeStrategy<ConditionNodeV1> = {
  execute(node, context): Promise<NodeResultV1> {
    const value = context.variables[node.config.variable];

    if (typeof value !== "string") {
      return Promise.resolve({
        type: "fail",
        code: "missing_condition_variable",
        message:
          `Condition variable ${node.config.variable} is not available as text`,
        details: { variable: node.config.variable },
      });
    }

    return Promise.resolve({
      type: "advance",
      route: { kind: "condition", value },
    });
  },
};

export const endNodeStrategy: NodeStrategy<EndNodeV1> = {
  execute(): Promise<NodeResultV1> {
    return Promise.resolve({ type: "complete" });
  },
};

export function executeNodeStrategy(
  node: Readonly<FlowNodeV1>,
  context: ExecutionContextV1,
): Promise<NodeResultV1> {
  switch (node.type) {
    case "start":
      return startNodeStrategy.execute(node, context);
    case "send_message":
      return sendMessageNodeStrategy.execute(node, context);
    case "collect_input":
      return collectInputNodeStrategy.execute(node, context);
    case "condition":
      return conditionNodeStrategy.execute(node, context);
    case "end":
      return endNodeStrategy.execute(node, context);
  }
}
