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
