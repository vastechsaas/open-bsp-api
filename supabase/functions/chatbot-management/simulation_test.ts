import { assertEquals } from "../_shared/test_assert.ts";
import { simulateChatbotFlow } from "./simulation.ts";

function node(
  id: string,
  nodeType: string,
  config: Record<string, unknown> = {},
) {
  return {
    id,
    type: "chatbotNode",
    position: { x: 0, y: 0 },
    data: { node_type: nodeType, config },
  };
}

function edge(
  id: string,
  source: string,
  target: string,
  data: Record<string, unknown> = { kind: "default" },
) {
  return { id, source, target, data };
}

const graph = {
  nodes: [
    node("start", "start"),
    node("welcome", "send_message", { text: "Welcome" }),
    node("city", "collect_input", {
      prompt: "What is your city?",
      variable: "customer_city",
      required: true,
    }),
    node("route", "condition", { variable: "customer_city" }),
    node("lahore", "send_message", { text: "Lahore selected" }),
    node("other", "send_message", { text: "Other city selected" }),
    node("end", "end"),
  ],
  edges: [
    edge("e1", "start", "welcome"),
    edge("e2", "welcome", "city"),
    edge("e3", "city", "route"),
    edge("e4", "route", "lahore", {
      kind: "condition",
      operator: "equals",
      value: "Lahore",
    }),
    edge("e5", "route", "other"),
    edge("e6", "lahore", "end"),
    edge("e7", "other", "end"),
  ],
};

Deno.test("simulator compiles the editor graph and pauses for local input", async () => {
  const result = await simulateChatbotFlow(graph, { variables: {} });

  assertEquals(result.valid, true);
  if (!result.valid) return;
  assertEquals(result.status, "waiting");
  assertEquals(result.current_node_id, "city");
  assertEquals(result.outgoing_texts, ["Welcome", "What is your city?"]);
  assertEquals(result.variables, {});
});

Deno.test("simulator resumes deterministically without persistence context", async () => {
  const result = await simulateChatbotFlow(graph, {
    current_node_id: "city",
    variables: {},
    free_text_input: "LAHORE",
  });

  assertEquals(result.valid, true);
  if (!result.valid) return;
  assertEquals(result.status, "completed");
  assertEquals(result.outgoing_texts, ["Lahore selected"]);
  assertEquals(result.variables, { customer_city: "LAHORE" });
});

Deno.test("simulator returns structured compiler issues for an invalid graph", async () => {
  const result = await simulateChatbotFlow(
    { nodes: [node("end", "end")], edges: [] },
    { variables: {} },
  );

  assertEquals(result.valid, false);
  if (result.valid) return;
  assertEquals(
    result.issues.some((issue) => issue.code === "invalid_start_count"),
    true,
  );
});

Deno.test("simulator selects an interactive option without side effects", async () => {
  const interactiveGraph = {
    nodes: [
      node("start", "start"),
      node("buttons", "interactive_buttons", {
        body: "Choose",
        buttons: [{ id: "support", title: "Support" }],
      }),
      node("end", "end"),
    ],
    edges: [
      edge("start-edge", "start", "buttons"),
      edge("support-edge", "buttons", "end", {
        kind: "option",
        option_id: "support",
      }),
    ],
  };

  const waiting = await simulateChatbotFlow(interactiveGraph, {
    variables: {},
  });
  assertEquals(waiting.valid, true);
  if (!waiting.valid) return;
  assertEquals(waiting.waiting_for, "button");
  assertEquals(waiting.outgoing_messages[0]?.type, "interactive");

  const completed = await simulateChatbotFlow(interactiveGraph, {
    current_node_id: "buttons",
    variables: {},
    option_input: { kind: "button", id: "support" },
  });
  assertEquals(completed.valid, true);
  if (!completed.valid) return;
  assertEquals(completed.status, "completed");
});

Deno.test("simulator uses webhook mocks and never performs an external request", async () => {
  const webhookGraph = {
    nodes: [
      node("start", "start"),
      node("lookup", "webhook", {
        method: "GET",
        url: "https://api.example.com/customers",
        headers: [],
        timeout_ms: 1000,
        retry_count: 0,
        response_mappings: [
          { variable: "customer_tier", path: "data.tier" },
        ],
      }),
      node("success", "send_message", { text: "Tier {{customer_tier}}" }),
      node("error", "send_message", { text: "Lookup failed" }),
      node("end", "end"),
    ],
    edges: [
      edge("e1", "start", "lookup"),
      edge("e2", "lookup", "success", {
        kind: "webhook",
        outcome: "success",
      }),
      edge("e3", "lookup", "error", {
        kind: "webhook",
        outcome: "error",
      }),
      edge("e4", "success", "end"),
      edge("e5", "error", "end"),
    ],
  };

  const result = await simulateChatbotFlow(webhookGraph, {
    variables: {},
    webhook_mocks: {
      lookup: {
        outcome: "success",
        status_code: 200,
        body: { data: { tier: "gold" } },
      },
    },
  });

  assertEquals(result.valid, true);
  if (!result.valid) return;
  assertEquals(result.status, "completed");
  assertEquals(result.outgoing_texts, ["Tier gold"]);
  assertEquals(result.variables, { customer_tier: "gold" });
});
