import { assertEquals } from "../test_assert.ts";
import { compileFlowDefinition, type CompileIssue } from "./compiler.ts";

function editorNode(
  id: string,
  nodeType: string,
  config: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    id,
    type: "chatbotNode",
    position: { x: 100, y: 200 },
    selected: false,
    width: 240,
    height: 80,
    data: {
      node_type: nodeType,
      label: `Visible ${nodeType} label`,
      config,
      editor_only: true,
    },
  };
}

function editorEdge(
  id: string,
  source: string,
  target: string,
  data: Record<string, unknown> = { kind: "default" },
): Record<string, unknown> {
  return {
    id,
    source,
    target,
    selected: false,
    animated: true,
    type: "smoothstep",
    data: { ...data, editor_only: true },
  };
}

function representativeGraph(): Record<string, unknown> {
  return {
    viewport: { x: 0, y: 0, zoom: 1 },
    nodes: [
      editorNode("start-1", "start"),
      editorNode("input-1", "collect_input", {
        prompt: "Which city are you in?",
        variable: "customer_city",
        required: true,
      }),
      editorNode("condition-1", "condition", {
        variable: "customer_city",
      }),
      editorNode("message-1", "send_message", {
        text: "We deliver there.",
      }),
      editorNode("end-1", "end"),
    ],
    edges: [
      editorEdge("edge-1", "start-1", "input-1"),
      editorEdge("edge-2", "input-1", "condition-1"),
      editorEdge("edge-3", "condition-1", "message-1", {
        kind: "condition",
        operator: "equals",
        value: "Lahore",
      }),
      editorEdge("edge-4", "condition-1", "end-1"),
      editorEdge("edge-5", "message-1", "end-1"),
    ],
  };
}

function issueCodes(graph: unknown): string[] {
  const result = compileFlowDefinition(graph);
  if (result.ok) throw new Error("Expected compilation to fail");
  return result.issues.map((issue) => issue.code);
}

function compileIssues(graph: unknown): ReadonlyArray<CompileIssue> {
  const result = compileFlowDefinition(graph);
  if (result.ok) throw new Error("Expected compilation to fail");
  return result.issues;
}

Deno.test("compiler creates a version 2 text menu with global commands", () => {
  const graph = {
    settings: {
      commands: {
        main_menu: { keyword: "M", target_node_id: "menu" },
        close: { keyword: "C", message: "Closed" },
      },
    },
    nodes: [
      editorNode("start", "start"),
      editorNode("menu", "text_menu", {
        prompt: "Type 1 for support",
        variable: "menu_choice",
        options: [{ id: "support", value: "1", label: "Support" }],
        invalid_response: "Invalid choice",
        max_retries: 3,
      }),
      editorNode("end", "end"),
    ],
    edges: [
      editorEdge("start-menu", "start", "menu"),
      editorEdge("menu-end", "menu", "end", {
        kind: "option",
        option_id: "support",
      }),
    ],
  };
  const result = compileFlowDefinition(graph);
  assertEquals(result.ok, true);
  if (!result.ok) return;
  assertEquals(result.definition.schema_version, 2);
  assertEquals(result.definition.commands?.main_menu.target_node_id, "menu");
});

Deno.test("compiles a five-node editor graph into the exact runtime definition", () => {
  const result = compileFlowDefinition(representativeGraph());
  if (!result.ok) throw new Error(JSON.stringify(result.issues));

  assertEquals(result.definition, {
    schema_version: 1,
    start_node_id: "start-1",
    nodes: [
      { id: "start-1", type: "start", config: {} },
      {
        id: "input-1",
        type: "collect_input",
        config: {
          prompt: "Which city are you in?",
          variable: "customer_city",
          required: true,
        },
      },
      {
        id: "condition-1",
        type: "condition",
        config: { variable: "customer_city" },
      },
      {
        id: "message-1",
        type: "send_message",
        config: { text: "We deliver there." },
      },
      { id: "end-1", type: "end", config: {} },
    ],
    edges: [
      { id: "edge-1", source: "start-1", target: "input-1", kind: "default" },
      {
        id: "edge-2",
        source: "input-1",
        target: "condition-1",
        kind: "default",
      },
      {
        id: "edge-3",
        source: "condition-1",
        target: "message-1",
        kind: "condition",
        operator: "equals",
        value: "Lahore",
      },
      { id: "edge-4", source: "condition-1", target: "end-1", kind: "default" },
      { id: "edge-5", source: "message-1", target: "end-1", kind: "default" },
    ],
  });
});

Deno.test("accepts templates using variables collected on every preceding path", () => {
  const graph = representativeGraph();
  const message = (graph.nodes as Record<string, unknown>[]).find(
    (node) => node.id === "message-1",
  )!;
  (
    (message.data as Record<string, unknown>).config as Record<string, unknown>
  ).text = "We deliver to {{ customer_city }}.";

  const result = compileFlowDefinition(graph);
  if (!result.ok) throw new Error(JSON.stringify(result.issues));
  assertEquals(
    result.definition.nodes.find((node) => node.id === "message-1")?.config,
    { text: "We deliver to {{ customer_city }}." },
  );
});

Deno.test("rejects malformed and path-unavailable template variables", () => {
  const malformed = representativeGraph();
  const malformedMessage = (malformed.nodes as Record<string, unknown>[]).find(
    (node) => node.id === "message-1",
  )!;
  (
    (malformedMessage.data as Record<string, unknown>)
      .config as Record<string, unknown>
  ).text = "Hello {{customer_city";
  assertEquals(
    issueCodes(malformed).includes("invalid_template_syntax"),
    true,
  );

  const unavailable = representativeGraph();
  const unavailableMessage = (
    unavailable.nodes as Record<string, unknown>[]
  ).find((node) => node.id === "message-1")!;
  (
    (unavailableMessage.data as Record<string, unknown>)
      .config as Record<string, unknown>
  ).text = "Hello {{customer_name}}";
  const issues = compileIssues(unavailable);
  const issue = issues.find(
    (candidate) => candidate.code === "template_variable_unavailable",
  );
  assertEquals(issue?.path, [
    "nodes",
    3,
    "data",
    "config",
    "text",
  ]);
});

Deno.test("invalid graph shape returns issues and never throws", () => {
  assertEquals(issueCodes(null), ["invalid_graph_shape"]);
  assertEquals(issueCodes({ nodes: "bad" }), [
    "invalid_graph_shape",
    "invalid_graph_shape",
  ]);
});

Deno.test("reports missing and duplicate starts", () => {
  const missing = representativeGraph();
  (missing.nodes as Record<string, unknown>[]).shift();
  assertEquals(issueCodes(missing).includes("invalid_start_count"), true);

  const duplicate = representativeGraph();
  (duplicate.nodes as Record<string, unknown>[]).push(
    editorNode("start-2", "start"),
  );
  assertEquals(issueCodes(duplicate).includes("invalid_start_count"), true);
});

Deno.test("reports duplicate IDs and dangling edge endpoints", () => {
  const graph = representativeGraph();
  (graph.nodes as Record<string, unknown>[]).push(
    editorNode("end-1", "end"),
  );
  (graph.edges as Record<string, unknown>[]).push(
    editorEdge("edge-1", "missing-source", "missing-target"),
  );

  const codes = issueCodes(graph);
  assertEquals(codes.includes("duplicate_node_id"), true);
  assertEquals(codes.includes("duplicate_edge_id"), true);
  assertEquals(codes.includes("dangling_edge_source"), true);
  assertEquals(codes.includes("dangling_edge_target"), true);
});

Deno.test("reports invalid node routing and conditional edge origins", () => {
  const graph = representativeGraph();
  (graph.edges as Record<string, unknown>[]).push(
    editorEdge("edge-6", "message-1", "end-1", {
      kind: "condition",
      operator: "contains",
      value: "yes",
    }),
  );
  (graph.edges as Record<string, unknown>[]).push(
    editorEdge("edge-7", "end-1", "start-1"),
  );

  const codes = issueCodes(graph);
  assertEquals(codes.includes("conditional_edge_source"), true);
  assertEquals(codes.includes("default_route_required"), true);
  assertEquals(codes.includes("terminal_has_outgoing_edge"), true);
  assertEquals(codes.includes("start_has_incoming_edge"), true);

  const conditionGraph = representativeGraph();
  const defaultBranch = (conditionGraph.edges as Record<string, unknown>[])
    .find((edge) => edge.id === "edge-4")!;
  defaultBranch.data = {
    kind: "condition",
    operator: "not_equals",
    value: "Lahore",
  };
  assertEquals(
    issueCodes(conditionGraph).includes("condition_fallback_required"),
    true,
  );
});

Deno.test("assign_agent is a configured terminal node", () => {
  const agentId = "11111111-1111-4111-8111-111111111111";
  const graph = {
    nodes: [
      editorNode("start", "start"),
      editorNode("handoff", "assign_agent", { agent_id: agentId }),
    ],
    edges: [editorEdge("to-handoff", "start", "handoff")],
  };

  const result = compileFlowDefinition(graph);
  if (!result.ok) throw new Error(JSON.stringify(result.issues));
  assertEquals(result.definition.nodes[1], {
    id: "handoff",
    type: "assign_agent",
    config: { agent_id: agentId },
  });

  (graph.edges as Record<string, unknown>[]).push(
    editorEdge("invalid-outgoing", "handoff", "start"),
  );
  assertEquals(
    issueCodes(graph).includes("terminal_has_outgoing_edge"),
    true,
  );
});

Deno.test("handoff acknowledgment is optional, bounded and reports its own field", () => {
  for (
    const acknowledgment_text of [
      undefined,
      "Connecting you.",
      " ",
      "x".repeat(4097),
    ]
  ) {
    const result = compileFlowDefinition({
      nodes: [
        editorNode("start", "start"),
        editorNode("handoff", "assign_agent", {
          routing_queue_id: "33333333-3333-4333-8333-333333333333",
          ...(acknowledgment_text === undefined ? {} : { acknowledgment_text }),
        }),
      ],
      edges: [editorEdge("to-handoff", "start", "handoff")],
    });
    if (
      acknowledgment_text === undefined ||
      acknowledgment_text === "Connecting you."
    ) {
      assertEquals(result.ok, true);
    } else {
      if (result.ok) throw new Error("Invalid acknowledgment accepted");
      assertEquals(result.issues.map((issue) => issue.code), [
        "handoff_acknowledgment_invalid",
      ]);
      assertEquals(result.issues[0].field, "acknowledgment_text");
    }
  }
});

Deno.test("interactive options compile to exact option edges", () => {
  const graph = {
    nodes: [
      editorNode("start", "start"),
      editorNode("buttons", "interactive_buttons", {
        body: "Choose",
        buttons: [
          { id: "sales", title: "Sales" },
          { id: "support", title: "Support" },
        ],
      }),
      editorNode("sales-end", "end"),
      editorNode("support-end", "end"),
    ],
    edges: [
      editorEdge("start-edge", "start", "buttons"),
      editorEdge("sales-edge", "buttons", "sales-end", {
        kind: "option",
        option_id: "sales",
      }),
      editorEdge("support-edge", "buttons", "support-end", {
        kind: "option",
        option_id: "support",
      }),
    ],
  };

  const result = compileFlowDefinition(graph);
  if (!result.ok) throw new Error(JSON.stringify(result.issues));
  assertEquals(result.definition.edges[1], {
    id: "sales-edge",
    source: "buttons",
    target: "sales-end",
    kind: "option",
    option_id: "sales",
  });
});

Deno.test("interactive nodes require one known edge per unique option", () => {
  const graph = {
    nodes: [
      editorNode("start", "start"),
      editorNode("buttons", "interactive_buttons", {
        body: "Choose",
        buttons: [
          { id: "sales", title: "Sales" },
          { id: "sales", title: "Support" },
        ],
      }),
      editorNode("end", "end"),
    ],
    edges: [
      editorEdge("start-edge", "start", "buttons"),
      editorEdge("unknown-edge", "buttons", "end", {
        kind: "option",
        option_id: "unknown",
      }),
    ],
  };

  const codes = issueCodes(graph);
  assertEquals(codes.includes("duplicate_option_id"), true);
  assertEquals(codes.includes("option_route_missing"), true);
});

Deno.test("reports unreachable nodes", () => {
  const graph = representativeGraph();
  (graph.nodes as Record<string, unknown>[]).push(
    editorNode("unused-end", "end"),
  );

  assertEquals(issueCodes(graph).includes("unreachable_node"), true);
});

Deno.test("rejects cycles", () => {
  const graph = representativeGraph();
  const edges = graph.edges as Record<string, unknown>[];
  const messageEdge = edges.find((edge) => edge.id === "edge-5")!;
  messageEdge.target = "input-1";

  assertEquals(issueCodes(graph).includes("cycle_detected"), true);
});

Deno.test("condition variables must be collected on every preceding path", () => {
  const unknownVariableGraph = representativeGraph();
  const condition = (unknownVariableGraph.nodes as Record<string, unknown>[])
    .find((node) => node.id === "condition-1")!;
  (condition.data as Record<string, unknown>).config = {
    variable: "unknown_value",
  };
  assertEquals(
    issueCodes(unknownVariableGraph).includes("condition_variable_unavailable"),
    true,
  );

  const partialPathGraph = representativeGraph();
  const nodes = partialPathGraph.nodes as Record<string, unknown>[];
  nodes.splice(
    1,
    0,
    editorNode("message-before-input", "send_message", {
      text: "Alternate path",
    }),
  );
  const edges = partialPathGraph.edges as Record<string, unknown>[];
  edges.push(
    editorEdge("edge-alt-1", "start-1", "message-before-input"),
    editorEdge("edge-alt-2", "message-before-input", "condition-1"),
  );

  const codes = issueCodes(partialPathGraph);
  assertEquals(codes.includes("condition_variable_unavailable"), true);
});

Deno.test("returns structured schema issues for invalid authored values", () => {
  const graph = representativeGraph();
  const message = (graph.nodes as Record<string, unknown>[]).find((node) =>
    node.id === "message-1"
  )!;
  (message.data as Record<string, unknown>).config = { text: " ".repeat(5) };
  const conditionEdge = (graph.edges as Record<string, unknown>[]).find((
    edge,
  ) => edge.id === "edge-3")!;
  (conditionEdge.data as Record<string, unknown>).operator = "greater_than";

  const issues = compileIssues(graph);
  const nodeIssue = issues.find((issue) =>
    issue.code === "message_text_required"
  )!;
  const edgeIssue = issues.find((issue) => issue.code === "invalid_edge")!;

  assertEquals(nodeIssue.node_id, "message-1");
  assertEquals(edgeIssue.edge_id, "edge-3");
  assertEquals(Array.isArray(nodeIssue.path), true);
  assertEquals(typeof nodeIssue.message, "string");
});

Deno.test("missing handoff queue returns one actionable root issue", () => {
  const graph = {
    nodes: [
      editorNode("start", "start"),
      editorNode("menu", "list_message", {
        body: "Choose",
        button_text: "Open",
        sections: [{
          id: "support",
          title: "Support",
          rows: [{ id: "vip", title: "VIP" }],
        }],
      }),
      editorNode("handoff", "assign_agent", {}),
    ],
    edges: [
      editorEdge("start-menu", "start", "menu"),
      editorEdge("menu-handoff", "menu", "handoff", {
        kind: "option",
        option_id: "vip",
      }),
    ],
  };

  const issues = compileIssues(graph);
  assertEquals(issues.length, 1);
  assertEquals(issues[0].code, "handoff_queue_required");
  assertEquals(issues[0].path, ["nodes", 2, "config"]);
  assertEquals(issues[0].message, "Destination queue is required");
  assertEquals(issues[0].node_id, "handoff");
  assertEquals(issues[0].field, "routing_queue_id");
  assertEquals(issues[0].category, "configuration");
});

Deno.test("invalid configured nodes retain graph identity", () => {
  const graph = representativeGraph();
  const message = (graph.nodes as Record<string, unknown>[]).find((node) =>
    node.id === "message-1"
  )!;
  (message.data as Record<string, unknown>).config = { text: "" };

  const codes = issueCodes(graph);
  assertEquals(codes.includes("message_text_required"), true);
  assertEquals(codes.includes("dangling_edge_source"), false);
  assertEquals(codes.includes("dangling_edge_target"), false);
  assertEquals(codes.includes("option_route_missing"), false);
  assertEquals(codes.includes("unreachable_node"), false);
  assertEquals(codes.includes("cycle_detected"), false);
  assertEquals(codes.includes("template_variable_unavailable"), false);
});

Deno.test("genuinely missing targets still return dangling diagnostics", () => {
  const graph = representativeGraph();
  const edge = (graph.edges as Record<string, unknown>[]).find((candidate) =>
    candidate.id === "edge-5"
  )!;
  edge.target = "deleted-node";

  const issues = compileIssues(graph);
  assertEquals(
    issues.some((issue) =>
      issue.code === "dangling_edge_target" &&
      issue.field === "target" &&
      issue.category === "connection"
    ),
    true,
  );
});

Deno.test("independent node configuration mistakes are all returned", () => {
  const graph = representativeGraph();
  const input = (graph.nodes as Record<string, unknown>[]).find((node) =>
    node.id === "input-1"
  )!;
  (input.data as Record<string, unknown>).config = {
    prompt: "",
    variable: "not valid",
    required: true,
  };
  const message = (graph.nodes as Record<string, unknown>[]).find((node) =>
    node.id === "message-1"
  )!;
  (message.data as Record<string, unknown>).config = { text: "" };

  const codes = issueCodes(graph);
  assertEquals(codes.includes("input_prompt_required"), true);
  assertEquals(codes.includes("input_variable_invalid"), true);
  assertEquals(codes.includes("message_text_required"), true);
});

Deno.test("node configuration errors use actionable codes and fields", () => {
  const cases: ReadonlyArray<{
    nodeType: string;
    config: Record<string, unknown>;
    code: string;
    field: string;
  }> = [
    {
      nodeType: "send_message",
      config: { text: "" },
      code: "message_text_required",
      field: "text",
    },
    {
      nodeType: "collect_input",
      config: { prompt: "", variable: "answer", required: true },
      code: "input_prompt_required",
      field: "prompt",
    },
    {
      nodeType: "collect_input",
      config: { prompt: "Answer", variable: "not valid", required: true },
      code: "input_variable_invalid",
      field: "variable",
    },
    {
      nodeType: "interactive_buttons",
      config: { body: "Choose", buttons: [] },
      code: "options_required",
      field: "buttons",
    },
    {
      nodeType: "list_message",
      config: { body: "Choose", button_text: "Open", sections: [] },
      code: "options_required",
      field: "sections",
    },
    {
      nodeType: "text_menu",
      config: {
        prompt: "Choose",
        variable: "choice",
        options: [],
        invalid_response: "Try again",
        max_retries: 3,
      },
      code: "options_required",
      field: "options",
    },
    {
      nodeType: "condition",
      config: { variable: "not valid" },
      code: "condition_variable_required",
      field: "variable",
    },
    {
      nodeType: "webhook",
      config: {
        method: "GET",
        url: "http://unsafe.example.com",
        headers: [],
        timeout_ms: 1000,
        retry_count: 0,
        response_mappings: [],
      },
      code: "webhook_url_invalid",
      field: "url",
    },
  ];

  for (const testCase of cases) {
    const graph = {
      nodes: [
        editorNode("start", "start"),
        editorNode("invalid", testCase.nodeType, testCase.config),
        editorNode("end", "end"),
      ],
      edges: [
        editorEdge("to-invalid", "start", "invalid"),
        editorEdge("to-end", "invalid", "end"),
      ],
    };
    const issue = compileIssues(graph).find((candidate) =>
      candidate.code === testCase.code
    );
    assertEquals(issue?.field, testCase.field);
    assertEquals(issue?.category, "configuration");
  }
});

Deno.test("issue ordering is deterministic", () => {
  const graph = representativeGraph();
  (graph.edges as Record<string, unknown>[]).push(
    editorEdge("edge-6", "missing", "also-missing"),
  );

  assertEquals(compileIssues(graph), compileIssues(graph));
});

Deno.test("webhook response variables are available only on the success route", () => {
  const baseNodes = [
    editorNode("start", "start"),
    editorNode("webhook", "webhook", {
      method: "GET",
      url: "https://api.example.com/customer",
      headers: [],
      timeout_ms: 1000,
      retry_count: 0,
      response_mappings: [{ variable: "customer_tier", path: "data.tier" }],
    }),
    editorNode("success", "send_message", { text: "{{customer_tier}}" }),
    editorNode("error", "send_message", { text: "Lookup failed" }),
    editorNode("end", "end"),
  ];
  const edges = [
    editorEdge("e1", "start", "webhook"),
    editorEdge("e2", "webhook", "success", {
      kind: "webhook",
      outcome: "success",
    }),
    editorEdge("e3", "webhook", "error", {
      kind: "webhook",
      outcome: "error",
    }),
    editorEdge("e4", "success", "end"),
    editorEdge("e5", "error", "end"),
  ];

  const valid = compileFlowDefinition({ nodes: baseNodes, edges });
  assertEquals(valid.ok, true);

  const invalid = compileFlowDefinition({
    nodes: baseNodes.map((node) =>
      node.id === "error"
        ? editorNode("error", "send_message", { text: "{{customer_tier}}" })
        : node
    ),
    edges,
  });
  assertEquals(invalid.ok, false);
  if (invalid.ok) return;
  assertEquals(
    invalid.issues.some((issue) =>
      issue.code === "template_variable_unavailable"
    ),
    true,
  );
});
