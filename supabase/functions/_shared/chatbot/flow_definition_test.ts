import { assertEquals } from "../test_assert.ts";
import {
  executionContextV1Schema,
  flowDefinitionV1Schema,
  flowEdgeV1Schema,
  flowNodeV1Schema,
  nodeResultV1Schema,
} from "./flow_definition.ts";

function assertValid(result: { success: boolean }): void {
  assertEquals(result.success, true);
}

function assertInvalid(result: { success: boolean }): void {
  assertEquals(result.success, false);
}

const nodes = [
  { id: "start-1", type: "start", config: {} },
  {
    id: "message_1",
    type: "send_message",
    config: { text: "Welcome" },
  },
  {
    id: "input-1",
    type: "collect_input",
    config: {
      prompt: "What is your city?",
      variable: "customer_city",
      required: true,
      min_length: 2,
      max_length: 80,
    },
  },
  {
    id: "condition-1",
    type: "condition",
    config: { variable: "customer_city" },
  },
  {
    id: "buttons-1",
    type: "interactive_buttons",
    config: {
      body: "Choose",
      buttons: [{ id: "support", title: "Support" }],
    },
  },
  {
    id: "list-1",
    type: "list_message",
    config: {
      body: "Choose",
      button_text: "Options",
      sections: [{
        id: "section-1",
        title: "Teams",
        rows: [{ id: "sales", title: "Sales" }],
      }],
    },
  },
  {
    id: "handoff-1",
    type: "assign_agent",
    config: { agent_id: "11111111-1111-4111-8111-111111111111" },
  },
  { id: "end-1", type: "end", config: {} },
];

Deno.test("FlowDefinitionV1 parses a valid definition", () => {
  const result = flowDefinitionV1Schema.safeParse({
    schema_version: 1,
    start_node_id: "start-1",
    nodes,
    edges: [
      { id: "edge-1", source: "start-1", target: "message_1", kind: "default" },
      {
        id: "edge-2",
        source: "condition-1",
        target: "end-1",
        kind: "condition",
        operator: "equals",
        value: "Lahore",
      },
    ],
  });

  assertValid(result);
});

Deno.test("every MVP node variant parses", () => {
  for (const node of nodes) {
    assertValid(flowNodeV1Schema.safeParse(node));
  }
});

Deno.test("default and every condition edge predicate parse", () => {
  assertValid(flowEdgeV1Schema.safeParse({
    id: "default-1",
    source: "source-1",
    target: "target-1",
    kind: "default",
  }));

  for (
    const operator of [
      "equals",
      "not_equals",
      "contains",
      "starts_with",
      "ends_with",
    ]
  ) {
    assertValid(flowEdgeV1Schema.safeParse({
      id: `condition-${operator}`,
      source: "source-1",
      target: "target-1",
      kind: "condition",
      operator,
      value: "expected",
    }));
  }

  assertValid(flowEdgeV1Schema.safeParse({
    id: "option-1",
    source: "source-1",
    target: "target-1",
    kind: "option",
    option_id: "sales",
  }));
});

Deno.test("invalid identifiers, variables, predicates, and node fields fail", () => {
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "bad id",
    type: "start",
    config: {},
  }));
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "input-1",
    type: "collect_input",
    config: {
      prompt: "Prompt",
      variable: "CustomerCity",
      required: true,
    },
  }));
  assertInvalid(flowEdgeV1Schema.safeParse({
    id: "edge-1",
    source: "source-1",
    target: "target-1",
    kind: "condition",
    operator: "greater_than",
    value: "1",
  }));
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "message-1",
    type: "send_message",
    config: { text: "   " },
  }));
});

Deno.test("input length limits are bounded and ordered", () => {
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "input-1",
    type: "collect_input",
    config: {
      prompt: "Prompt",
      variable: "answer",
      required: true,
      min_length: 10,
      max_length: 5,
    },
  }));
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "input-1",
    type: "collect_input",
    config: {
      prompt: "Prompt",
      variable: "answer",
      required: true,
      max_length: 4097,
    },
  }));
});

Deno.test("text is limited to WhatsApp text message length", () => {
  assertValid(flowNodeV1Schema.safeParse({
    id: "message-1",
    type: "send_message",
    config: { text: "a".repeat(4096) },
  }));
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "message-1",
    type: "send_message",
    config: { text: "a".repeat(4097) },
  }));
});

Deno.test("interactive WhatsApp limits are enforced", () => {
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "buttons-1",
    type: "interactive_buttons",
    config: {
      body: "Choose",
      buttons: [
        { id: "one", title: "One" },
        { id: "two", title: "Two" },
        { id: "three", title: "Three" },
        { id: "four", title: "Four" },
      ],
    },
  }));
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "list-1",
    type: "list_message",
    config: {
      body: "Choose",
      button_text: "Options",
      sections: [{
        id: "section-1",
        title: "Teams",
        rows: Array.from({ length: 11 }, (_, index) => ({
          id: `row-${index}`,
          title: `Row ${index}`,
        })),
      }],
    },
  }));
});

Deno.test("ExecutionContextV1 accepts immutable runtime data shape", () => {
  assertValid(executionContextV1Schema.safeParse({
    variables: {
      customer_city: "Lahore",
      profile: { opted_in: true },
    },
    free_text_input: "Lahore",
  }));
  assertInvalid(executionContextV1Schema.safeParse({
    variables: { "bad-key": "value" },
  }));
});

Deno.test("every NodeResultV1 variant parses", () => {
  const results = [
    {
      type: "advance",
      route: { kind: "default" },
      variable_updates: { customer_city: "Lahore" },
    },
    {
      type: "advance",
      route: { kind: "condition", value: "Lahore" },
    },
    {
      type: "emit_message",
      message: { type: "text", text: "Hello" },
      route: { kind: "default" },
    },
    {
      type: "wait_for_input",
      prompt: "What is your city?",
      expectation: {
        kind: "free_text",
        variable: "customer_city",
        required: true,
        min_length: 2,
        max_length: 80,
      },
    },
    {
      type: "wait_for_input",
      message: {
        type: "interactive",
        interactive: {
          type: "button",
          body: { text: "Choose" },
          action: {
            buttons: [{
              type: "reply",
              reply: { id: "sales", title: "Sales" },
            }],
          },
        },
      },
      expectation: { kind: "button", option_ids: ["sales"] },
    },
    { type: "complete" },
    {
      type: "handoff",
      agent_id: "11111111-1111-4111-8111-111111111111",
    },
    {
      type: "fail",
      code: "invalid-input",
      message: "The input was invalid",
      details: { received: null },
    },
  ];

  for (const result of results) {
    assertValid(nodeResultV1Schema.safeParse(result));
  }
});

Deno.test("assign_agent requires a UUID agent reference", () => {
  assertInvalid(flowNodeV1Schema.safeParse({
    id: "handoff",
    type: "assign_agent",
    config: { agent_id: "not-an-agent-id" },
  }));
});

Deno.test("NodeResultV1 rejects infrastructure commands and invalid data", () => {
  assertInvalid(nodeResultV1Schema.safeParse({
    type: "request_effect",
    effect: { url: "https://example.com" },
  }));
  assertInvalid(nodeResultV1Schema.safeParse({
    type: "wait_for_input",
    prompt: "Prompt",
    expectation: {
      kind: "free_text",
      variable: "Answer",
      required: true,
    },
  }));
});
