import {
  bridgeDefinitionHash,
  canonicalBridgeJson,
  translatePublishedDefinition,
} from "./node_bridge_translation.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const node = (id: string, type: string, config: unknown = {}) => ({
  id,
  type,
  config,
});
const edge = (source: string, target: string, extra: unknown = {}) => ({
  id: `${source}_${target}`,
  source,
  target,
  kind: "default",
  ...extra as object,
});
const flow = (nodes: unknown[], edges: unknown[]) => ({
  schema_version: 1,
  start_node_id: "start",
  nodes: [node("start", "start"), ...nodes],
  edges,
});
function rejected(
  definition: unknown,
  credentials?: Record<string, Record<string, string>>,
) {
  let rejected = false;
  try {
    translatePublishedDefinition(definition, credentials);
  } catch (error) {
    rejected = error instanceof Error &&
      error.message.startsWith("UNSUPPORTED_BRIDGE_CONFIGURATION");
  }
  assert(rejected, "Expected unsupported configuration rejection");
}

Deno.test("bridge: text preserves IDs and variable references", () => {
  const graph = translatePublishedDefinition(flow([
    node("message", "send_message", { text: "Hello {{name}}" }),
    node("end", "end"),
  ], [edge("start", "message"), edge("message", "end")]));
  assert(graph.nodes[1].id === "message");
  assert(graph.nodes[1].data.nodeType === "MESSAGE");
  assert(graph.nodes[1].data.config.text === "Hello {{name}}");
  assert(graph.edges.every((item) => item.sourceHandle === "*"));
  assert(graph.bridge.required_capability === "openbsp-flow-v1");
});

Deno.test("bridge: buttons and lists preserve exact option IDs", () => {
  for (
    const [type, config] of [
      ["interactive_buttons", {
        body: "Choose",
        buttons: [{ id: "Yes_ID", title: "Yes" }],
      }],
      ["list_message", {
        body: "Choose",
        button_text: "Menu",
        sections: [
          {
            id: "section",
            title: "Choices",
            rows: [{ id: "Yes_ID", title: "Yes", description: "Details" }],
          },
        ],
      }],
    ] as const
  ) {
    const definition = flow([node("menu", type, config), node("end", "end")], [
      edge("start", "menu"),
      edge("menu", "end", { kind: "option", option_id: "Yes_ID" }),
    ]);
    const graph = translatePublishedDefinition(definition);
    assert(graph.edges[1].sourceHandle === "Yes_ID");
    assert(graph.nodes[1].data.config.openbspInteractive === true);
    rejected({
      ...definition,
      edges: [edge("start", "menu"), edge("menu", "end")],
    });
  }
});

Deno.test("bridge: button-rendered lists become chunkable Node button menus", () => {
  const definition = flow([
    node("menu", "list_message", {
      body: "Choose",
      button_text: "Menu",
      render_as_buttons: true,
      sections: [{
        id: "section",
        title: "Choices",
        rows: [
          { id: "one", title: "One" },
          { id: "two", title: "Two" },
          { id: "three", title: "Three" },
          { id: "four", title: "Four" },
        ],
      }],
    }),
    node("end-one", "end"),
    node("end-two", "end"),
    node("end-three", "end"),
    node("end-four", "end"),
  ], [
    edge("start", "menu"),
    edge("menu", "end-one", { kind: "option", option_id: "one" }),
    edge("menu", "end-two", { kind: "option", option_id: "two" }),
    edge("menu", "end-three", { kind: "option", option_id: "three" }),
    edge("menu", "end-four", { kind: "option", option_id: "four" }),
  ]);

  const graph = translatePublishedDefinition(definition);
  assert(graph.nodes[1].data.nodeType === "BUTTON");
  const buttons = graph.nodes[1].data.config.buttons as Array<{
    id: string;
    title: string;
  }>;
  assert(buttons.length === 4);
  assert(buttons[3].id === "four");
});

Deno.test("bridge: input carries required and length rules without regex reinterpretation", () => {
  const graph = translatePublishedDefinition(flow([
    node("input", "collect_input", {
      prompt: "Your name?",
      variable: "name",
      required: false,
      min_length: 2,
      max_length: 20,
    }),
    node("end", "end"),
  ], [edge("start", "input"), edge("input", "end")]));
  const config = graph.nodes[1].data.config;
  assert(config.variableName === "name");
  assert(
    canonicalBridgeJson(config.openbspInput) ===
      '{"max_length":20,"min_length":2,"required":false}',
  );
});

Deno.test("bridge: conditions keep first-match order, literals and defaults", () => {
  for (
    const operator of [
      "equals",
      "not_equals",
      "contains",
      "starts_with",
      "ends_with",
    ]
  ) {
    const graph = translatePublishedDefinition(flow([
      node("check", "condition", { variable: "answer" }),
      node("a", "end"),
      node("b", "end"),
      node("fallback", "end"),
    ], [
      edge("start", "check"),
      edge("check", "a", {
        kind: "condition",
        operator,
        value: " {{literal}} ",
      }),
      edge("check", "b", { kind: "condition", operator: "equals", value: "B" }),
      edge("check", "fallback"),
    ]));
    const check = graph.nodes.find((item) => item.id === "check")!;
    assert(
      canonicalBridgeJson(check.data.config.openbspCondition).includes(
        "{{literal}}",
      ),
    );
    const next = graph.edges.find((item) =>
      item.source === "check" && item.sourceHandle === "false"
    )!;
    assert(next.target.startsWith("openbsp_bridge_condition_"));
    assert(
      graph.edges.some((item) =>
        item.source === next.target && item.sourceHandle === "false" &&
        item.target === "fallback"
      ),
    );
  }
});

Deno.test("bridge: webhook retains milliseconds, retries, mappings and secret references", () => {
  const secret = "11111111-1111-4111-8111-111111111111";
  const definition = flow([
    node("api", "webhook", {
      method: "POST",
      url: "https://example.com/api",
      headers: [{ name: "Accept", value: "application/json" }],
      body_template: '{"name":"{{name}}"}',
      secret_id: secret,
      timeout_ms: 500,
      retry_count: 2,
      response_mappings: [{ variable: "result", path: "data.result" }],
    }),
    node("ok", "end"),
    node("error", "end"),
  ], [
    edge("start", "api"),
    edge("api", "ok", { kind: "webhook", outcome: "success" }),
    edge("api", "error", { kind: "webhook", outcome: "error" }),
  ]);
  rejected(definition);
  const graph = translatePublishedDefinition(definition, {
    [secret]: { Authorization: "OPENBSP_API_TOKEN" },
  });
  const config = graph.nodes[1].data.config;
  assert(config.timeoutMs === 500);
  assert(canonicalBridgeJson(config.retry) === '{"max":2}');
  assert(
    canonicalBridgeJson(config.headers).includes("{{env.OPENBSP_API_TOKEN}}"),
  );
  assert(canonicalBridgeJson(config.responseMapping).includes("data.result"));
  assert(graph.edges[2].sourceHandle === "error");
});

Deno.test("bridge: handoff keeps OpenBSP UUID target, never a Node agent ID", () => {
  for (const target of ["agent_id", "routing_queue_id"]) {
    const graph = translatePublishedDefinition(flow([
      node("handoff", "assign_agent", {
        [target]: "11111111-1111-4111-8111-111111111111",
      }),
    ], [edge("start", "handoff")]));
    assert(graph.nodes[1].data.nodeType === "ASSIGN_AGENT");
    assert(
      canonicalBridgeJson(graph.nodes[1].data.config.openbspTarget).includes(
        target,
      ),
    );
  }
});

Deno.test("bridge: invalid, unsupported, cyclic and incomplete graphs fail closed", () => {
  rejected(flow([node("ai", "ai_process")], [edge("start", "ai")]));
  rejected(
    flow([node("end", "end"), node("end", "end")], [edge("start", "end")]),
  );
  rejected(flow([node("end", "end")], [edge("start", "missing")]));
  rejected(
    flow([node("message", "send_message", { text: "Loop" })], [
      edge("start", "message"),
      edge("message", "start"),
    ]),
  );
  rejected(
    flow([node("end", "end"), node("unused", "end")], [edge("start", "end")]),
  );
});

Deno.test("bridge: hash ignores object key order, not behavior or route order", async () => {
  const graph = translatePublishedDefinition(
    flow([node("end", "end")], [edge("start", "end")]),
  );
  assert(
    canonicalBridgeJson({ b: 2, a: 1 }) === canonicalBridgeJson({ a: 1, b: 2 }),
  );
  assert(
    await bridgeDefinitionHash(graph) ===
      await bridgeDefinitionHash(structuredClone(graph)),
  );
  assert((await bridgeDefinitionHash(graph)).length === 64);
});
