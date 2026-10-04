import { assertEquals } from "../test_assert.ts";
import { compileFlowDefinition } from "./compiler.ts";
import { interpretFlowDefinitionV1 } from "./interpreter.ts";
import { normalizeCustomerPhone } from "./system_variables.ts";
import { simulateChatbotFlow } from "../../chatbot-management/simulation.ts";

const node = (id: string, node_type: string, config: object = {}) => ({
  id,
  data: { node_type, config },
});
const edge = (
  source: string,
  target: string,
  data: object = { kind: "default" },
) => ({
  id: `${source}_${target}`,
  source,
  target,
  data,
});
const phoneGraph = {
  nodes: [
    node("start", "start"),
    node("message", "send_message", {
      text: "Your number: {{customer_phone}}",
    }),
    node("end", "end"),
  ],
  edges: [edge("start", "message"), edge("message", "end")],
};

Deno.test("customer phone normalizes trusted international identity without guessing", () => {
  assertEquals(normalizeCustomerPhone("923001234567"), "+923001234567");
  assertEquals(normalizeCustomerPhone("+14155552671"), "+14155552671");
  for (
    const invalid of [
      undefined,
      923001234567,
      "03001234567",
      "92300 1234567",
      "1234567890123456",
      "{{customer_phone}}",
      "",
    ]
  ) {
    assertEquals(normalizeCustomerPhone(invalid), undefined);
  }
});

Deno.test("system phone is available from start and trusted context overrides stale session values", async () => {
  const compiled = compileFlowDefinition(phoneGraph);
  assertEquals(compiled.ok, true);
  if (!compiled.ok) return;
  const result = await interpretFlowDefinitionV1(compiled.definition, {
    current_node_id: "start",
    variables: { customer_phone: "+19999999999" },
    customer_phone: "923001234567",
  });
  assertEquals(result.status, "completed");
  assertEquals(result.outgoing_texts, ["Your number: +923001234567"]);
  assertEquals(result.variables, {});
  const missing = await interpretFlowDefinitionV1(compiled.definition, {
    current_node_id: "start",
    variables: { customer_phone: "+19999999999" },
  });
  assertEquals(missing.status, "failed");
  const simulated = await simulateChatbotFlow(phoneGraph, {
    variables: { customer_phone: "spoofed" },
  });
  assertEquals(simulated.valid, true);
  if (simulated.valid) {
    assertEquals(simulated.outgoing_texts, ["Your number: +923001234567"]);
  }
});

Deno.test("input, text menu and API mappings cannot overwrite system variables", () => {
  const configs = [
    node("write", "collect_input", {
      prompt: "Number?",
      variable: "customer_phone",
      required: true,
    }),
    node("write", "text_menu", {
      prompt: "Choose",
      variable: "customer_phone",
      options: [{ id: "a", value: "1", label: "One" }],
      invalid_response: "Retry",
      max_retries: 3,
    }),
    node("write", "webhook", {
      method: "POST",
      url: "https://example.com/plans",
      headers: [],
      timeout_ms: 1000,
      retry_count: 0,
      body_template: '{"phone_number":"{{customer_phone}}"}',
      response_mappings: [{ variable: "customer_phone", path: "phone" }],
    }),
  ];
  for (const write of configs) {
    const result = compileFlowDefinition({
      nodes: [node("start", "start"), write, node("end", "end")],
      edges: [edge("start", "write"), edge("write", "end")],
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
      assertEquals(result.issues.map((issue) => issue.code), [
        "system_variable_read_only",
      ]);
    }
  }
});

Deno.test("API body and phone conditions can read the built-in without an input prompt", async () => {
  const graph = {
    nodes: [
      node("start", "start"),
      node("api", "webhook", {
        method: "POST",
        url: "https://example.com/plans",
        headers: [],
        timeout_ms: 1000,
        retry_count: 0,
        body_template: '{"phone_number":"{{customer_phone}}"}',
        response_mappings: [],
      }),
      node("route", "condition", { variable: "customer_phone" }),
      node("end", "end"),
    ],
    edges: [
      edge("start", "api"),
      edge("api", "route", { kind: "webhook", outcome: "success" }),
      edge("api", "end", { kind: "webhook", outcome: "error" }),
      edge("route", "end", {
        kind: "condition",
        operator: "starts_with",
        value: "+92",
      }),
      { ...edge("route", "end"), id: "fallback" },
    ],
  };
  const compiled = compileFlowDefinition(graph);
  assertEquals(compiled.ok, true);
  if (!compiled.ok) return;
  const result = await interpretFlowDefinitionV1(compiled.definition, {
    current_node_id: "start",
    variables: {},
    customer_phone: "923001234567",
    webhook_executor: (_node, context) => {
      assertEquals(context.customer_phone, "+923001234567");
      return Promise.resolve({
        ok: true,
        variable_updates: { customer_phone: "spoofed" },
      });
    },
  });
  assertEquals(result.status, "completed");
  assertEquals(result.variables, {});
});
