import type { CompileIssue, FlowDefinitionV1 } from "../_shared/chatbot/mod.ts";

export function assignedHumanAgentIds(
  definition: FlowDefinitionV1,
): string[] {
  return [
    ...new Set(
      definition.nodes.flatMap((node) =>
        node.type === "assign_agent" ? [node.config.agent_id] : []
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
