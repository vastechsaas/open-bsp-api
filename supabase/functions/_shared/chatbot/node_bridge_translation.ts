import {
  type FlowDefinitionV1,
  flowDefinitionV1Schema,
} from "./flow_definition.ts";

/** Versioned server-side contract. Never translate editor_graph or credentials. */
export const NODE_BRIDGE_TRANSLATOR_VERSION = 1;

export type NodeBridgeGraph = {
  bridge: { translator_version: 1; required_capability: "openbsp-flow-v1" };
  nodes: Array<{
    id: string;
    type: "chatbotNode";
    data: { nodeType: string; config: Record<string, unknown> };
  }>;
  edges: Array<{
    id: string;
    source: string;
    target: string;
    sourceHandle: string;
  }>;
};

function unsupported(message: string): never {
  throw new Error(`UNSUPPORTED_BRIDGE_CONFIGURATION: ${message}`);
}

/** Stable graph serialization for hashing and ambiguous-request reconciliation. */
export function canonicalBridgeJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map(canonicalBridgeJson).join(",")}]`;
  }
  return `{${
    Object.entries(value).filter(([, item]) => item !== undefined)
      .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .map(([key, item]) =>
        `${JSON.stringify(key)}:${canonicalBridgeJson(item)}`
      )
      .join(",")
  }}`;
}

export async function bridgeDefinitionHash(graph: NodeBridgeGraph) {
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonicalBridgeJson(graph)),
  );
  return [...new Uint8Array(bytes)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

export function translatePublishedDefinition(
  definition: unknown,
  // Only server-resolved secret KEY references; never plaintext or ciphertext.
  credentialKeys: Readonly<Record<string, Readonly<Record<string, string>>>> =
    {},
): NodeBridgeGraph {
  const parsed = flowDefinitionV1Schema.safeParse(definition);
  if (!parsed.success) {
    unsupported("A validated schema_version=1 definition is required");
  }
  const flow: FlowDefinitionV1 = parsed.data;
  const ids = new Set(flow.nodes.map((node) => node.id));
  if (ids.size !== flow.nodes.length) unsupported("Duplicate node IDs");
  if (
    flow.nodes.filter((node) => node.type === "start").length !== 1 ||
    !flow.nodes.some((node) =>
      node.id === flow.start_node_id && node.type === "start"
    )
  ) {
    unsupported("Exactly one matching start node is required");
  }
  if (new Set(flow.edges.map((edge) => edge.id)).size !== flow.edges.length) {
    unsupported("Duplicate edge IDs");
  }
  for (const edge of flow.edges) {
    if (!ids.has(edge.source) || !ids.has(edge.target)) {
      unsupported(`Dangling edge ${edge.id}`);
    }
  }
  const graph: NodeBridgeGraph = {
    bridge: { translator_version: 1, required_capability: "openbsp-flow-v1" },
    nodes: [],
    edges: [],
  };
  const addNode = (
    id: string,
    nodeType: string,
    config: Record<string, unknown>,
  ) => {
    graph.nodes.push({
      id,
      type: "chatbotNode",
      data: { nodeType, config: { ...config, openbspText: true } },
    });
  };
  const addEdge = (
    id: string,
    source: string,
    target: string,
    sourceHandle: string,
  ) => {
    graph.edges.push({ id, source, target, sourceHandle });
  };
  let generated = 0;
  const auxiliaryId = () => {
    let id: string;
    do {
      id = `openbsp_bridge_condition_${++generated}`;
    } while (ids.has(id));
    ids.add(id);
    return id;
  };
  for (const node of flow.nodes) {
    const outgoing = flow.edges.filter((edge) => edge.source === node.id);
    const defaults = outgoing.filter((edge) => edge.kind === "default");
    const config = node.config;
    switch (node.type) {
      case "condition": {
        const predicates = outgoing.filter((edge) => edge.kind === "condition");
        if (
          defaults.length !== 1 || predicates.length === 0 ||
          outgoing.length !== predicates.length + 1
        ) unsupported(`Invalid condition routing at ${node.id}`);
        // Ordered first-match semantics, not an unordered OR group.
        const chain = predicates.map((_, index) =>
          index === 0 ? node.id : auxiliaryId()
        );
        predicates.forEach((edge, index) => {
          addNode(chain[index], "CONDITION", {
            openbspCondition: {
              variable: node.config.variable,
              operator: edge.operator,
              value: edge.value,
            },
          });
          addEdge(`${chain[index]}_true`, chain[index], edge.target, "true");
          addEdge(
            `${chain[index]}_false`,
            chain[index],
            chain[index + 1] ?? defaults[0].target,
            "false",
          );
        });
        continue;
      }
      case "start":
        addNode(node.id, "START", {});
        break;
      case "end":
        addNode(node.id, "END", {});
        break;
      case "send_message":
        addNode(node.id, "MESSAGE", { text: node.config.text });
        break;
      case "interactive_buttons":
        addNode(node.id, "BUTTON", {
          text: node.config.body,
          buttons: node.config.buttons,
          openbspInteractive: true,
          maxRetries: 0,
        });
        break;
      case "list_message":
        if (node.config.render_as_buttons) {
          addNode(node.id, "BUTTON", {
            text: node.config.body,
            buttons: node.config.sections.flatMap((section) =>
              section.rows.map((row) => ({ id: row.id, title: row.title }))
            ),
            openbspInteractive: true,
            maxRetries: 0,
          });
        } else {
          addNode(node.id, "LIST", {
            text: node.config.body,
            buttonText: node.config.button_text,
            sections: node.config.sections,
            openbspInteractive: true,
            maxRetries: 0,
          });
        }
        break;
      case "collect_input":
        addNode(node.id, "INPUT", {
          promptText: node.config.prompt,
          variableName: node.config.variable,
          openbspInput: {
            required: node.config.required,
            min_length: node.config.min_length,
            max_length: node.config.max_length,
          },
        });
        break;
      case "assign_agent":
        addNode(node.id, "ASSIGN_AGENT", { openbspTarget: config });
        break;
      case "webhook": {
        const secrets = node.config.secret_id
          ? credentialKeys[node.config.secret_id]
          : {};
        if (!secrets) {
          unsupported(`Protected credential is unresolved at ${node.id}`);
        }
        const headers = node.config.headers.map((header) => ({
          key: header.name,
          value: header.value,
        }));
        for (const [header, key] of Object.entries(secrets)) {
          if (!/^[A-Z][A-Z0-9_]{0,63}$/.test(key)) {
            unsupported(`Invalid vault key at ${node.id}`);
          }
          headers.push({ key: header, value: `{{env.${key}}}` });
        }
        addNode(node.id, "WEBHOOK", {
          url: node.config.url,
          method: node.config.method,
          headers,
          body: node.config.body_template,
          timeoutMs: node.config.timeout_ms,
          retryEnabled: node.config.retry_count > 0,
          retry: { max: node.config.retry_count },
          responseMapping: node.config.response_mappings.map((item) => ({
            variableName: item.variable,
            jsonPath: item.path,
          })),
          openbspWebhook: true,
        });
        break;
      }
    }
    if (
      ["start", "send_message", "collect_input"].includes(node.type) &&
      (defaults.length !== 1 || outgoing.length !== 1)
    ) unsupported(`Invalid continuation at ${node.id}`);
    if (["end", "assign_agent"].includes(node.type) && outgoing.length) {
      unsupported(`Terminal node has outgoing edges at ${node.id}`);
    }
    if (
      node.type === "webhook" && (outgoing.length !== 2 ||
        !outgoing.some((edge) =>
          edge.kind === "webhook" && edge.outcome === "success"
        ) ||
        !outgoing.some((edge) =>
          edge.kind === "webhook" && edge.outcome === "error"
        ))
    ) unsupported(`Invalid webhook routing at ${node.id}`);
    if (node.type === "interactive_buttons" || node.type === "list_message") {
      const options = node.type === "interactive_buttons"
        ? node.config.buttons.map((item) => item.id)
        : node.config.sections.flatMap((section) =>
          section.rows.map((row) => row.id)
        );
      if (
        new Set(options).size !== options.length ||
        outgoing.length !== options.length ||
        options.some((id) =>
          outgoing.filter((edge) =>
            edge.kind === "option" && edge.option_id === id
          ).length !== 1
        )
      ) {
        unsupported(`Every option needs one exact route at ${node.id}`);
      }
    }
    for (const edge of outgoing) {
      const handle = edge.kind === "default"
        ? "*"
        : edge.kind === "option"
        ? edge.option_id
        : edge.kind === "webhook"
        ? edge.outcome
        : unsupported(`Invalid edge kind at ${node.id}`);
      addEdge(edge.id, edge.source, edge.target, handle);
    }
  }
  // Definition must remain acyclic and fully reachable, even if stored JSON is tampered with.
  const visiting = new Set<string>();
  const visited = new Set<string>();
  const visit = (id: string) => {
    if (visiting.has(id)) unsupported(`Cycle at ${id}`);
    if (visited.has(id)) return;
    visiting.add(id);
    for (const edge of graph.edges.filter((item) => item.source === id)) {
      visit(edge.target);
    }
    visiting.delete(id);
    visited.add(id);
  };
  visit(flow.start_node_id);
  if (visited.size !== graph.nodes.length) unsupported("Unreachable nodes");
  // Node's execution budget is 100 automatic steps per customer turn. Reject
  // translated condition chains that would exceed it rather than truncate replies.
  const depths = new Map<string, number>();
  const depth = (id: string): number => {
    if (depths.has(id)) return depths.get(id)!;
    const node = graph.nodes.find((item) => item.id === id)!;
    const waiting = ["INPUT", "BUTTON", "LIST", "ASSIGN_AGENT", "END"].includes(
      node.data.nodeType,
    );
    const result = 1 +
      (waiting ? 0 : Math.max(
        0,
        ...graph.edges.filter((edge) => edge.source === id).map((edge) =>
          depth(edge.target)
        ),
      ));
    depths.set(id, result);
    return result;
  };
  if (graph.nodes.some((node) => depth(node.id) > 100)) {
    unsupported("More than 100 automatic steps between customer inputs");
  }
  return graph;
}
