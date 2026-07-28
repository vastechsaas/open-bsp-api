import {
  type FlowDefinitionV1,
  type FlowEdgeV1,
  flowEdgeV1Schema,
  type FlowNodeV1,
  flowNodeV1Schema,
} from "./flow_definition.ts";
import { parseChatbotTemplate } from "./template.ts";

export interface CompileIssue {
  readonly code: string;
  readonly path: ReadonlyArray<string | number>;
  readonly message: string;
  readonly node_id?: string;
  readonly edge_id?: string;
}

export type CompileFlowResult =
  | { readonly ok: true; readonly definition: FlowDefinitionV1 }
  | { readonly ok: false; readonly issues: ReadonlyArray<CompileIssue> };

interface EditorNode {
  readonly id?: unknown;
  readonly type?: unknown;
  readonly data?: unknown;
}

interface EditorEdge {
  readonly id?: unknown;
  readonly source?: unknown;
  readonly target?: unknown;
  readonly sourceHandle?: unknown;
  readonly data?: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function issuePathCompare(
  left: ReadonlyArray<string | number>,
  right: ReadonlyArray<string | number>,
): number {
  for (let index = 0; index < Math.min(left.length, right.length); index++) {
    const leftPart = left[index];
    const rightPart = right[index];

    if (leftPart === rightPart) continue;
    if (typeof leftPart === "number" && typeof rightPart === "number") {
      return leftPart - rightPart;
    }

    return String(leftPart).localeCompare(String(rightPart));
  }

  return left.length - right.length;
}

function sortIssues(issues: CompileIssue[]): CompileIssue[] {
  return issues.sort((left, right) =>
    issuePathCompare(left.path, right.path) ||
    left.code.localeCompare(right.code) ||
    left.message.localeCompare(right.message)
  );
}

function editorNodeToCandidate(node: EditorNode): unknown {
  const data = isRecord(node.data) ? node.data : {};
  const nodeType = data.node_type ?? node.type;

  return {
    id: node.id,
    type: nodeType,
    config: data.config ?? {},
  };
}

function editorEdgeToCandidate(edge: EditorEdge): unknown {
  const data = isRecord(edge.data) ? edge.data : {};
  const kind = data.kind ?? "default";

  if (kind === "condition") {
    return {
      id: edge.id,
      source: edge.source,
      target: edge.target,
      kind,
      operator: data.operator,
      value: data.value,
    };
  }

  if (kind === "option") {
    return {
      id: edge.id,
      source: edge.source,
      target: edge.target,
      kind,
      option_id: data.option_id ?? edge.sourceHandle,
    };
  }

  return {
    id: edge.id,
    source: edge.source,
    target: edge.target,
    kind,
  };
}

function addDuplicateIssues(
  values: ReadonlyArray<{ readonly id: string }>,
  sourceIndexes: ReadonlyArray<number>,
  collection: "nodes" | "edges",
  code: string,
  issues: CompileIssue[],
): boolean {
  const seen = new Set<string>();
  let hasDuplicate = false;

  values.forEach((value, index) => {
    if (seen.has(value.id)) {
      hasDuplicate = true;
      issues.push({
        code,
        path: [collection, sourceIndexes[index], "id"],
        message: `Duplicate ${collection.slice(0, -1)} ID '${value.id}'`,
        ...(collection === "nodes"
          ? { node_id: value.id }
          : { edge_id: value.id }),
      });
    }
    seen.add(value.id);
  });

  return hasDuplicate;
}

function findCycle(
  nodes: ReadonlyArray<FlowNodeV1>,
  adjacency: ReadonlyMap<string, ReadonlyArray<string>>,
): string | undefined {
  const visited = new Set<string>();
  const active = new Set<string>();

  function visit(nodeId: string): string | undefined {
    if (active.has(nodeId)) return nodeId;
    if (visited.has(nodeId)) return undefined;

    visited.add(nodeId);
    active.add(nodeId);
    for (const target of adjacency.get(nodeId) ?? []) {
      const cycleNode = visit(target);
      if (cycleNode !== undefined) return cycleNode;
    }
    active.delete(nodeId);
    return undefined;
  }

  for (const node of nodes) {
    const cycleNode = visit(node.id);
    if (cycleNode !== undefined) return cycleNode;
  }

  return undefined;
}

function intersectSets(sets: ReadonlyArray<ReadonlySet<string>>): Set<string> {
  if (sets.length === 0) return new Set();

  const intersection = new Set(sets[0]);
  for (const value of intersection) {
    if (sets.slice(1).some((set) => !set.has(value))) {
      intersection.delete(value);
    }
  }
  return intersection;
}

function validateAvailableVariables(
  nodes: ReadonlyArray<FlowNodeV1>,
  nodeSourceIndexes: ReadonlyMap<FlowNodeV1, number>,
  edges: ReadonlyArray<FlowEdgeV1>,
  startNodeId: string,
  reachable: ReadonlySet<string>,
  issues: CompileIssue[],
): void {
  const nodeById = new Map(nodes.map((node) => [node.id, node]));
  const incoming = new Map<string, string[]>();
  const outgoing = new Map<string, string[]>();
  const indegree = new Map<string, number>();

  for (const node of nodes) {
    if (!reachable.has(node.id)) continue;
    incoming.set(node.id, []);
    outgoing.set(node.id, []);
    indegree.set(node.id, 0);
  }

  for (const edge of edges) {
    if (!reachable.has(edge.source) || !reachable.has(edge.target)) continue;
    incoming.get(edge.target)?.push(edge.source);
    outgoing.get(edge.source)?.push(edge.target);
    indegree.set(edge.target, (indegree.get(edge.target) ?? 0) + 1);
  }

  const queue = nodes.filter((node) =>
    reachable.has(node.id) && (indegree.get(node.id) ?? 0) === 0
  ).map((node) => node.id);
  const outputVariables = new Map<string, ReadonlySet<string>>();

  while (queue.length > 0) {
    const nodeId = queue.shift()!;
    const node = nodeById.get(nodeId)!;
    const predecessorSets = (incoming.get(nodeId) ?? []).map((predecessor) =>
      outputVariables.get(predecessor) ?? new Set<string>()
    );
    const available = nodeId === startNodeId
      ? new Set<string>()
      : intersectSets(predecessorSets);

    const templateFields: ReadonlyArray<
      readonly [field: string, template: string]
    > = node.type === "send_message"
      ? [["text", node.config.text]]
      : node.type === "collect_input"
      ? [["prompt", node.config.prompt]]
      : node.type === "interactive_buttons" || node.type === "list_message"
      ? [["body", node.config.body]]
      : [];

    for (const [field, template] of templateFields) {
      const parsedTemplate = parseChatbotTemplate(template);
      const path = [
        "nodes",
        nodeSourceIndexes.get(node)!,
        "data",
        "config",
        field,
      ];
      if (!parsedTemplate.ok) {
        issues.push({
          code: "invalid_template_syntax",
          path,
          message: parsedTemplate.message,
          node_id: node.id,
        });
        continue;
      }
      for (const variable of parsedTemplate.variables) {
        if (!available.has(variable)) {
          issues.push({
            code: "template_variable_unavailable",
            path,
            message:
              `Variable '${variable}' is not collected on every path to this node`,
            node_id: node.id,
          });
        }
      }
    }

    if (node.type === "condition" && !available.has(node.config.variable)) {
      issues.push({
        code: "condition_variable_unavailable",
        path: [
          "nodes",
          nodeSourceIndexes.get(node)!,
          "data",
          "config",
          "variable",
        ],
        message:
          `Variable '${node.config.variable}' is not collected on every path to this condition`,
        node_id: node.id,
      });
    }

    if (node.type === "collect_input") {
      available.add(node.config.variable);
    }
    outputVariables.set(nodeId, available);

    for (const target of outgoing.get(nodeId) ?? []) {
      const nextIndegree = (indegree.get(target) ?? 0) - 1;
      indegree.set(target, nextIndegree);
      if (nextIndegree === 0) queue.push(target);
    }
  }
}

/**
 * Converts a React Flow editor document into the versioned runtime definition.
 * Editor-only properties are ignored, and user-authored invalid input is always
 * returned as structured issues rather than thrown.
 */
export function compileFlowDefinition(editorGraph: unknown): CompileFlowResult {
  const issues: CompileIssue[] = [];

  if (!isRecord(editorGraph)) {
    return {
      ok: false,
      issues: [{
        code: "invalid_graph_shape",
        path: [],
        message: "Editor graph must be an object",
      }],
    };
  }

  if (!Array.isArray(editorGraph.nodes)) {
    issues.push({
      code: "invalid_graph_shape",
      path: ["nodes"],
      message: "Editor graph nodes must be an array",
    });
  }
  if (!Array.isArray(editorGraph.edges)) {
    issues.push({
      code: "invalid_graph_shape",
      path: ["edges"],
      message: "Editor graph edges must be an array",
    });
  }
  if (issues.length > 0) return { ok: false, issues: sortIssues(issues) };

  const rawNodes = editorGraph.nodes as unknown[];
  const rawEdges = editorGraph.edges as unknown[];
  const nodes: FlowNodeV1[] = [];
  const edges: FlowEdgeV1[] = [];
  const nodeSourceIndexes = new Map<FlowNodeV1, number>();
  const edgeSourceIndexes = new Map<FlowEdgeV1, number>();

  rawNodes.forEach((rawNode, index) => {
    if (!isRecord(rawNode)) {
      issues.push({
        code: "invalid_node",
        path: ["nodes", index],
        message: "Node must be an object",
      });
      return;
    }

    const result = flowNodeV1Schema.safeParse(
      editorNodeToCandidate(rawNode as EditorNode),
    );
    if (result.success) {
      nodes.push(result.data);
      nodeSourceIndexes.set(result.data, index);
      return;
    }

    for (const validationIssue of result.error.issues) {
      issues.push({
        code: "invalid_node",
        path: [
          "nodes",
          index,
          ...validationIssue.path.map((part) =>
            typeof part === "symbol" ? String(part) : part
          ),
        ],
        message: validationIssue.message,
        ...(typeof rawNode.id === "string" ? { node_id: rawNode.id } : {}),
      });
    }
  });

  rawEdges.forEach((rawEdge, index) => {
    if (!isRecord(rawEdge)) {
      issues.push({
        code: "invalid_edge",
        path: ["edges", index],
        message: "Edge must be an object",
      });
      return;
    }

    const result = flowEdgeV1Schema.safeParse(
      editorEdgeToCandidate(rawEdge as EditorEdge),
    );
    if (result.success) {
      edges.push(result.data);
      edgeSourceIndexes.set(result.data, index);
      return;
    }

    for (const validationIssue of result.error.issues) {
      issues.push({
        code: "invalid_edge",
        path: [
          "edges",
          index,
          ...validationIssue.path.map((part) =>
            typeof part === "symbol" ? String(part) : part
          ),
        ],
        message: validationIssue.message,
        ...(typeof rawEdge.id === "string" ? { edge_id: rawEdge.id } : {}),
      });
    }
  });

  const hasDuplicateNodes = addDuplicateIssues(
    nodes,
    nodes.map((node) => nodeSourceIndexes.get(node)!),
    "nodes",
    "duplicate_node_id",
    issues,
  );
  const hasDuplicateEdges = addDuplicateIssues(
    edges,
    edges.map((edge) => edgeSourceIndexes.get(edge)!),
    "edges",
    "duplicate_edge_id",
    issues,
  );
  const startNodes = nodes.filter((node) => node.type === "start");
  const terminalNodes = nodes.filter((node) =>
    node.type === "end" || node.type === "assign_agent"
  );

  if (startNodes.length !== 1) {
    issues.push({
      code: "invalid_start_count",
      path: ["nodes"],
      message: `Expected exactly one start node, found ${startNodes.length}`,
    });
  }
  if (terminalNodes.length === 0) {
    issues.push({
      code: "missing_terminal_node",
      path: ["nodes"],
      message: "Expected at least one end or assign-agent node",
    });
  }

  const nodeIds = new Set(nodes.map((node) => node.id));
  edges.forEach((edge) => {
    if (!nodeIds.has(edge.source)) {
      issues.push({
        code: "dangling_edge_source",
        path: ["edges", edgeSourceIndexes.get(edge)!, "source"],
        message: `Edge source '${edge.source}' does not exist`,
        edge_id: edge.id,
      });
    }
    if (!nodeIds.has(edge.target)) {
      issues.push({
        code: "dangling_edge_target",
        path: ["edges", edgeSourceIndexes.get(edge)!, "target"],
        message: `Edge target '${edge.target}' does not exist`,
        edge_id: edge.id,
      });
    }
  });

  const validEdges = edges.filter((edge) =>
    nodeIds.has(edge.source) && nodeIds.has(edge.target)
  );
  const nodeById = new Map(nodes.map((node) => [node.id, node]));

  validEdges.forEach((edge) => {
    if (
      edge.kind === "condition" &&
      nodeById.get(edge.source)?.type !== "condition"
    ) {
      issues.push({
        code: "conditional_edge_source",
        path: ["edges", edgeSourceIndexes.get(edge)!, "data", "kind"],
        message: "Conditional edges may originate only from condition nodes",
        edge_id: edge.id,
      });
    }
    if (
      edge.kind === "option" &&
      !["interactive_buttons", "list_message"].includes(
        nodeById.get(edge.source)?.type ?? "",
      )
    ) {
      issues.push({
        code: "option_edge_source",
        path: ["edges", edgeSourceIndexes.get(edge)!, "data", "kind"],
        message:
          "Option edges may originate only from interactive button or list nodes",
        edge_id: edge.id,
      });
    }
  });

  nodes.forEach((node) => {
    const nodeIndex = nodeSourceIndexes.get(node)!;
    const incoming = validEdges.filter((edge) => edge.target === node.id);
    const outgoing = validEdges.filter((edge) => edge.source === node.id);
    const defaults = outgoing.filter((edge) => edge.kind === "default");
    const conditions = outgoing.filter((edge) => edge.kind === "condition");
    const options = outgoing.filter((edge) => edge.kind === "option");

    if (node.type === "start") {
      if (incoming.length !== 0) {
        issues.push({
          code: "start_has_incoming_edge",
          path: ["nodes", nodeIndex],
          message: "Start node must not have incoming edges",
          node_id: node.id,
        });
      }
      if (outgoing.length !== 1 || defaults.length !== 1) {
        issues.push({
          code: "invalid_start_routing",
          path: ["nodes", nodeIndex],
          message: "Start node must have exactly one default outgoing edge",
          node_id: node.id,
        });
      }
    }

    if (node.type === "send_message" || node.type === "collect_input") {
      if (outgoing.length !== 1 || defaults.length !== 1) {
        issues.push({
          code: "invalid_default_routing",
          path: ["nodes", nodeIndex],
          message:
            `${node.type} node must have exactly one default outgoing edge`,
          node_id: node.id,
        });
      }
    }

    if (
      node.type === "interactive_buttons" || node.type === "list_message"
    ) {
      const configuredOptionIds = node.type === "interactive_buttons"
        ? node.config.buttons.map((button) => button.id)
        : node.config.sections.flatMap((section) =>
          section.rows.map((row) => row.id)
        );
      const uniqueConfiguredOptionIds = new Set(configuredOptionIds);
      const routedOptionIds = options.map((edge) => edge.option_id);
      const uniqueRoutedOptionIds = new Set(routedOptionIds);

      if (uniqueConfiguredOptionIds.size !== configuredOptionIds.length) {
        issues.push({
          code: "duplicate_option_id",
          path: ["nodes", nodeIndex, "data", "config"],
          message: "Interactive option IDs must be unique within a node",
          node_id: node.id,
        });
      }

      if (
        outgoing.length !== configuredOptionIds.length ||
        options.length !== outgoing.length ||
        uniqueRoutedOptionIds.size !== routedOptionIds.length ||
        configuredOptionIds.some((optionId) =>
          !uniqueRoutedOptionIds.has(optionId)
        ) ||
        routedOptionIds.some((optionId) =>
          !uniqueConfiguredOptionIds.has(optionId)
        )
      ) {
        issues.push({
          code: "invalid_option_routing",
          path: ["nodes", nodeIndex],
          message:
            `${node.type} node must have exactly one option edge for every configured option`,
          node_id: node.id,
        });
      }
    }

    if (node.type === "condition") {
      if (defaults.length !== 1 || conditions.length === 0) {
        issues.push({
          code: "invalid_condition_routing",
          path: ["nodes", nodeIndex],
          message:
            "Condition node must have exactly one default edge and at least one conditional edge",
          node_id: node.id,
        });
      }
    }

    if (
      (node.type === "end" || node.type === "assign_agent") &&
      outgoing.length !== 0
    ) {
      issues.push({
        code: "terminal_has_outgoing_edge",
        path: ["nodes", nodeIndex],
        message: "Terminal nodes must not have outgoing edges",
        node_id: node.id,
      });
    }
  });

  const adjacency = new Map<string, string[]>();
  for (const node of nodes) adjacency.set(node.id, []);
  for (const edge of validEdges) adjacency.get(edge.source)?.push(edge.target);

  const reachable = new Set<string>();
  if (startNodes.length === 1) {
    const queue = [startNodes[0].id];
    while (queue.length > 0) {
      const nodeId = queue.shift()!;
      if (reachable.has(nodeId)) continue;
      reachable.add(nodeId);
      queue.push(...(adjacency.get(nodeId) ?? []));
    }

    nodes.forEach((node) => {
      if (!reachable.has(node.id)) {
        issues.push({
          code: "unreachable_node",
          path: ["nodes", nodeSourceIndexes.get(node)!],
          message: `Node '${node.id}' is not reachable from start`,
          node_id: node.id,
        });
      }
    });
  }

  const cycleNode = !hasDuplicateNodes && !hasDuplicateEdges
    ? findCycle(nodes, adjacency)
    : undefined;
  if (cycleNode !== undefined) {
    const cycleNodeValue = nodes.find((node) => node.id === cycleNode)!;
    issues.push({
      code: "cycle_detected",
      path: ["nodes", nodeSourceIndexes.get(cycleNodeValue)!],
      message: `Cycle detected at node '${cycleNode}'`,
      node_id: cycleNode,
    });
  }

  if (
    startNodes.length === 1 && cycleNode === undefined &&
    !hasDuplicateNodes && !hasDuplicateEdges
  ) {
    validateAvailableVariables(
      nodes,
      nodeSourceIndexes,
      validEdges,
      startNodes[0].id,
      reachable,
      issues,
    );
  }

  if (issues.length > 0) return { ok: false, issues: sortIssues(issues) };

  return {
    ok: true,
    definition: {
      schema_version: 1,
      start_node_id: startNodes[0].id,
      nodes,
      edges,
    },
  };
}
