import { assertEquals } from "../_shared/test_assert.ts";
import type { FlowDefinitionV1 } from "../_shared/chatbot/mod.ts";
import {
  assignedHumanAgentIds,
  findUnavailableAgentIssues,
} from "./agent_references.ts";

const availableAgentId = "11111111-1111-4111-8111-111111111111";
const unavailableAgentId = "22222222-2222-4222-8222-222222222222";

const definition: FlowDefinitionV1 = {
  schema_version: 1,
  start_node_id: "start",
  nodes: [
    { id: "start", type: "start", config: {} },
    {
      id: "handoff-one",
      type: "assign_agent",
      config: { agent_id: availableAgentId },
    },
    {
      id: "handoff-two",
      type: "assign_agent",
      config: { agent_id: unavailableAgentId },
    },
  ],
  edges: [],
};

Deno.test("assignment references are unique and unavailable agents are reported", () => {
  assertEquals(assignedHumanAgentIds(definition), [
    availableAgentId,
    unavailableAgentId,
  ]);
  assertEquals(
    findUnavailableAgentIssues(definition, new Set([availableAgentId])),
    [{
      code: "assign_agent_unavailable",
      path: ["nodes", 2, "data", "config", "agent_id"],
      message:
        "Assign Agent must reference an active human agent in this organization",
      node_id: "handoff-two",
    }],
  );
});
