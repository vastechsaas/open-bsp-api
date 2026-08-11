import type { CompileIssue, FlowDefinitionV1 } from "../_shared/chatbot/mod.ts";

export function assignedHumanAgentIds(
  definition: FlowDefinitionV1,
): string[] {
  return [
    ...new Set(
      definition.nodes.flatMap((node) =>
        node.type === "assign_agent" && "agent_id" in node.config
          ? [node.config.agent_id]
          : []
      ),
    ),
  ];
}

export function findUnavailableAgentIssues(
  definition: FlowDefinitionV1,
  availableAgentIds: ReadonlySet<string>,
): CompileIssue[] {
  return definition.nodes.flatMap((node, index) => {
    if (
      node.type !== "assign_agent" ||
      !("agent_id" in node.config) ||
      availableAgentIds.has(node.config.agent_id)
    ) {
      return [];
    }

    return [{
      code: "assign_agent_unavailable",
      path: ["nodes", index, "data", "config", "agent_id"],
      message:
        "Assign Agent must reference an active human agent in this organization",
      node_id: node.id,
    }];
  });
}

export function routingQueueIds(definition: FlowDefinitionV1): string[] {
  return [
    ...new Set(
      definition.nodes.flatMap((node) =>
        node.type === "assign_agent" && "routing_queue_id" in node.config
          ? [node.config.routing_queue_id]
          : []
      ),
    ),
  ];
}

export function findUnavailableRoutingQueueIssues(
  definition: FlowDefinitionV1,
  availableQueueIds: ReadonlySet<string>,
): CompileIssue[] {
  return definition.nodes.flatMap((node, index) => {
    if (
      node.type !== "assign_agent" ||
      !("routing_queue_id" in node.config) ||
      availableQueueIds.has(node.config.routing_queue_id)
    ) {
      return [];
    }

    return [{
      code: "routing_queue_unavailable",
      path: ["nodes", index, "data", "config", "routing_queue_id"],
      message:
        "Human Handoff must reference an active routing queue in this organization",
      node_id: node.id,
    }];
  });
}
