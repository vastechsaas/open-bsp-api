import { assertEquals } from "../test_assert.ts";
import type { FlowDefinitionV1 } from "./flow_definition.ts";
import {
  CHATBOT_MAX_AUTOMATIC_TRANSITIONS,
  conditionMatchesV1,
  interpretFlowDefinitionV1,
} from "./interpreter.ts";

const customerFlow: FlowDefinitionV1 = {
  schema_version: 1,
  start_node_id: "start",
  nodes: [
    { id: "start", type: "start", config: {} },
    {
      id: "welcome",
      type: "send_message",
      config: { text: "Welcome" },
    },
    {
      id: "collect-city",
      type: "collect_input",
      config: {
        prompt: "What is your city?",
        variable: "customer_city",
        required: true,
      },
    },
    {
      id: "route-city",
      type: "condition",
      config: { variable: "customer_city" },
    },
    {
      id: "lahore-message",
      type: "send_message",
      config: { text: "Lahore selected" },
    },
    {
      id: "other-message",
      type: "send_message",
      config: { text: "Other city selected" },
    },
    { id: "end", type: "end", config: {} },
  ],
  edges: [
    { id: "e1", source: "start", target: "welcome", kind: "default" },
    {
      id: "e2",
      source: "welcome",
      target: "collect-city",
      kind: "default",
    },
    {
      id: "e3",
      source: "collect-city",
      target: "route-city",
      kind: "default",
    },
    {
      id: "e4",
      source: "route-city",
      target: "lahore-message",
      kind: "condition",
      operator: "equals",
      value: "lahore",
    },
    {
      id: "e5",
      source: "route-city",
      target: "other-message",
      kind: "default",
    },
    {
      id: "e6",
      source: "lahore-message",
      target: "end",
      kind: "default",
    },
    {
      id: "e7",
      source: "other-message",
      target: "end",
      kind: "default",
    },
  ],
};

Deno.test("interpreter runs from start to the next wait", async () => {
  const result = await interpretFlowDefinitionV1(customerFlow, {
    current_node_id: "start",
    variables: {},
  });

  assertEquals(result, {
    status: "waiting",
    current_node_id: "collect-city",
    waiting_for: "free_text",
    variables: {},
    outgoing_texts: ["Welcome", "What is your city?"],
    outgoing_messages: [
      { type: "text", text: "Welcome" },
      { type: "text", text: "What is your city?" },
    ],
    error: null,
    transition_count: 3,
  });
});

Deno.test("interpreter resumes input and completes a matching branch", async () => {
  const result = await interpretFlowDefinitionV1(customerFlow, {
    current_node_id: "collect-city",
    variables: {},
    free_text_input: "  LAHORE ",
  });

  assertEquals(result, {
    status: "completed",
    current_node_id: "end",
    waiting_for: null,
    variables: { customer_city: "LAHORE" },
    outgoing_texts: ["Lahore selected"],
    outgoing_messages: [{ type: "text", text: "Lahore selected" }],
    error: null,
    transition_count: 4,
  });
});

Deno.test("interpreter renders a value collected earlier in the flow", async () => {
  const flow: FlowDefinitionV1 = {
    ...customerFlow,
    nodes: customerFlow.nodes.map((node) =>
      node.type === "send_message" && node.id === "lahore-message"
        ? {
          ...node,
          config: { text: "We deliver to {{customer_city}}" },
        }
        : node
    ),
  };

  const result = await interpretFlowDefinitionV1(flow, {
    current_node_id: "collect-city",
    variables: {},
    free_text_input: "Lahore",
  });

  assertEquals(result.outgoing_texts, ["We deliver to Lahore"]);
  assertEquals(result.status, "completed");
});

Deno.test("condition matching trims and ignores case for every operator", () => {
  assertEquals(conditionMatchesV1("equals", " Lahore ", "lahore"), true);
  assertEquals(conditionMatchesV1("not_equals", " Lahore ", "karachi"), true);
  assertEquals(
    conditionMatchesV1("contains", " North LAHORE ", "lahore"),
    true,
  );
  assertEquals(
    conditionMatchesV1("starts_with", " Lahore City ", "lahore"),
    true,
  );
  assertEquals(conditionMatchesV1("ends_with", "City Lahore ", "LAHORE"), true);
});

Deno.test("condition routing uses the first matching edge in definition order", async () => {
  const definition: FlowDefinitionV1 = {
    schema_version: 1,
    start_node_id: "condition",
    nodes: [
      {
        id: "condition",
        type: "condition",
        config: { variable: "answer" },
      },
      { id: "first", type: "end", config: {} },
      { id: "second", type: "end", config: {} },
      { id: "fallback", type: "end", config: {} },
    ],
    edges: [
      {
        id: "first-edge",
        source: "condition",
        target: "first",
        kind: "condition",
        operator: "contains",
        value: "alpha",
      },
      {
        id: "second-edge",
        source: "condition",
        target: "second",
        kind: "condition",
        operator: "starts_with",
        value: "alpha",
      },
      {
        id: "default-edge",
        source: "condition",
        target: "fallback",
        kind: "default",
      },
    ],
  };

  const result = await interpretFlowDefinitionV1(definition, {
    current_node_id: "condition",
    variables: { answer: " Alpha value " },
  });

  assertEquals(result.current_node_id, "first");
  assertEquals(result.status, "completed");
});

Deno.test("interpreter accumulates multiple automatic messages", async () => {
  const definition: FlowDefinitionV1 = {
    schema_version: 1,
    start_node_id: "first",
    nodes: [
      { id: "first", type: "send_message", config: { text: "One" } },
      { id: "second", type: "send_message", config: { text: "Two" } },
      { id: "end", type: "end", config: {} },
    ],
    edges: [
      { id: "e1", source: "first", target: "second", kind: "default" },
      { id: "e2", source: "second", target: "end", kind: "default" },
    ],
  };

  const result = await interpretFlowDefinitionV1(definition, {
    current_node_id: "first",
    variables: {},
  });

  assertEquals(result.outgoing_texts, ["One", "Two"]);
  assertEquals(result.status, "completed");
});

Deno.test("interactive buttons wait and route by exact reply ID", async () => {
  const definition: FlowDefinitionV1 = {
    schema_version: 1,
    start_node_id: "buttons",
    nodes: [
      {
        id: "buttons",
        type: "interactive_buttons",
        config: {
          body: "Choose a team",
          buttons: [
            { id: "sales", title: "Sales" },
            { id: "support", title: "Support" },
          ],
        },
      },
      { id: "sales-end", type: "end", config: {} },
      { id: "support-end", type: "end", config: {} },
    ],
    edges: [
      {
        id: "sales-edge",
        source: "buttons",
        target: "sales-end",
        kind: "option",
        option_id: "sales",
      },
      {
        id: "support-edge",
        source: "buttons",
        target: "support-end",
        kind: "option",
        option_id: "support",
      },
    ],
  };

  const waiting = await interpretFlowDefinitionV1(definition, {
    current_node_id: "buttons",
    variables: {},
  });
  assertEquals(waiting.waiting_for, "button");
  assertEquals(waiting.outgoing_texts, []);
  assertEquals(waiting.outgoing_messages[0]?.type, "interactive");

  const completed = await interpretFlowDefinitionV1(definition, {
    current_node_id: "buttons",
    variables: {},
    option_input: { kind: "button", id: "support" },
  });
  assertEquals(completed.status, "completed");
  assertEquals(completed.current_node_id, "support-end");

  const invalid = await interpretFlowDefinitionV1(definition, {
    current_node_id: "buttons",
    variables: {},
    option_input: { kind: "button", id: "unknown" },
  });
  assertEquals(invalid.status, "waiting");
  assertEquals(invalid.current_node_id, "buttons");
});

Deno.test("one invocation consumes free text only once", async () => {
  const definition: FlowDefinitionV1 = {
    schema_version: 1,
    start_node_id: "first-input",
    nodes: [
      {
        id: "first-input",
        type: "collect_input",
        config: { prompt: "First?", variable: "first", required: true },
      },
      {
        id: "second-input",
        type: "collect_input",
        config: { prompt: "Second?", variable: "second", required: true },
      },
      { id: "end", type: "end", config: {} },
    ],
    edges: [
      {
        id: "e1",
        source: "first-input",
        target: "second-input",
        kind: "default",
      },
      {
        id: "e2",
        source: "second-input",
        target: "end",
        kind: "default",
      },
    ],
  };

  const result = await interpretFlowDefinitionV1(definition, {
    current_node_id: "first-input",
    variables: {},
    free_text_input: "one answer",
  });

  assertEquals(result.status, "waiting");
  assertEquals(result.current_node_id, "second-input");
  assertEquals(result.variables, { first: "one answer" });
  assertEquals(result.outgoing_texts, ["Second?"]);
});

Deno.test("invalid stored definitions fail without throwing", async () => {
  const result = await interpretFlowDefinitionV1(
    {
      schema_version: 1,
      start_node_id: "message",
      nodes: [
        {
          id: "message",
          type: "send_message",
          config: { text: "   " },
        },
      ],
      edges: [],
    },
    { current_node_id: "message", variables: {} },
  );

  assertEquals(result.status, "failed");
  assertEquals(result.error?.code, "invalid_definition");
  assertEquals(result.transition_count, 0);
});

Deno.test("assign_agent ends interpretation with a side-effect request", async () => {
  const agentId = "11111111-1111-4111-8111-111111111111";
  const result = await interpretFlowDefinitionV1(
    {
      schema_version: 1,
      start_node_id: "handoff",
      nodes: [{
        id: "handoff",
        type: "assign_agent",
        config: { agent_id: agentId },
      }],
      edges: [],
    },
    { current_node_id: "handoff", variables: {} },
  );

  assertEquals(result.status, "handed_off");
  assertEquals(result.handoff_agent_id, agentId);
  assertEquals(result.outgoing_messages, []);
});

Deno.test("missing variables and missing edges become failure results", async () => {
  const missingVariable = await interpretFlowDefinitionV1(customerFlow, {
    current_node_id: "route-city",
    variables: {},
  });
  assertEquals(missingVariable.error?.code, "missing_condition_variable");

  const missingEdge = await interpretFlowDefinitionV1(
    {
      schema_version: 1,
      start_node_id: "message",
      nodes: [
        { id: "message", type: "send_message", config: { text: "Hello" } },
      ],
      edges: [],
    },
    { current_node_id: "message", variables: {} },
  );
  assertEquals(missingEdge.error?.code, "missing_route");
  assertEquals(missingEdge.outgoing_texts, ["Hello"]);
});

Deno.test("automatic traversal fails after 50 transitions", async () => {
  const definition: FlowDefinitionV1 = {
    schema_version: 1,
    start_node_id: "first",
    nodes: [
      { id: "first", type: "start", config: {} },
      { id: "second", type: "start", config: {} },
    ],
    edges: [
      { id: "e1", source: "first", target: "second", kind: "default" },
      { id: "e2", source: "second", target: "first", kind: "default" },
    ],
  };

  const result = await interpretFlowDefinitionV1(definition, {
    current_node_id: "first",
    variables: {},
  });

  assertEquals(result.status, "failed");
  assertEquals(result.error?.code, "transition_limit_exceeded");
  assertEquals(result.transition_count, CHATBOT_MAX_AUTOMATIC_TRANSITIONS);
});
