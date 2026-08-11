import { assertEquals } from "../_shared/test_assert.ts";
import type { FlowDefinitionV1 } from "../_shared/chatbot/mod.ts";
import {
  assignedHumanAgentIds,
  findUnavailableAgentIssues,
  findUnavailableRoutingQueueIssues,
  routingQueueIds,
} from "./agent_references.ts";

const availableAgentId = "11111111-1111-4111-8111-111111111111";
const unavailableAgentId = "22222222-2222-4222-8222-222222222222";
const availableQueueId = "33333333-3333-4333-8333-333333333333";
const unavailableQueueId = "44444444-4444-4444-8444-444444444444";

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
    {
      id: "handoff-queue-one",
      type: "assign_agent",
      config: { routing_queue_id: availableQueueId },
    },
    {
      id: "handoff-queue-two",
      type: "assign_agent",
      config: { routing_queue_id: unavailableQueueId },
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

Deno.test("routing queue references are unique and unavailable queues are reported", () => {
  assertEquals(routingQueueIds(definition), [
    availableQueueId,
    unavailableQueueId,
  ]);
  assertEquals(
    findUnavailableRoutingQueueIssues(
      definition,
      new Set([availableQueueId]),
    ),
    [{
      code: "routing_queue_unavailable",
      path: ["nodes", 4, "data", "config", "routing_queue_id"],
      message:
        "Human Handoff must reference an active routing queue in this organization",
      node_id: "handoff-queue-two",
    }],
  );
});
