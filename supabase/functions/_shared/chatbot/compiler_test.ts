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
  assertEquals(codes.includes("invalid_default_routing"), true);
  assertEquals(codes.includes("end_has_outgoing_edge"), true);
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
    issueCodes(conditionGraph).includes("invalid_condition_routing"),
    true,
  );
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
  const nodeIssue = issues.find((issue) => issue.code === "invalid_node")!;
  const edgeIssue = issues.find((issue) => issue.code === "invalid_edge")!;

  assertEquals(nodeIssue.node_id, "message-1");
  assertEquals(edgeIssue.edge_id, "edge-3");
  assertEquals(Array.isArray(nodeIssue.path), true);
  assertEquals(typeof nodeIssue.message, "string");
});

Deno.test("issue ordering is deterministic", () => {
  const graph = representativeGraph();
  (graph.edges as Record<string, unknown>[]).push(
    editorEdge("edge-6", "missing", "also-missing"),
  );

  assertEquals(compileIssues(graph), compileIssues(graph));
});
