import { assertEquals, assertThrows } from "../_shared/test_assert.ts";
import {
  activateDeploymentPayloadSchema,
  createFlowPayloadSchema,
  deploymentPayloadSchema,
  editorGraphSchema,
  publishDraftPayloadSchema,
  saveDraftPayloadSchema,
  simulateFlowPayloadSchema,
} from "./payload.ts";

const organizationId = "14000000-0000-4000-8000-000000000001";
const versionId = "84000000-0000-4000-8000-000000000001";
const updatedAt = "2026-07-26T12:00:00.000000+00:00";

Deno.test("create flow payload trims its name", () => {
  const payload = createFlowPayloadSchema.parse({
    organization_id: organizationId,
    name: "  Support Assistant  ",
  });

  assertEquals(payload.name, "Support Assistant");
});

Deno.test("editor graph requires React Flow node and edge arrays", () => {
  assertThrows(() => editorGraphSchema.parse({ nodes: {} }), "nodes");
  assertThrows(
    () => editorGraphSchema.parse({ nodes: [], edges: null }),
    "edges",
  );

  assertEquals(
    editorGraphSchema.parse({
      nodes: [],
      edges: [],
      viewport: { x: 10, y: 20, zoom: 1 },
    }),
    {
      nodes: [],
      edges: [],
      viewport: { x: 10, y: 20, zoom: 1 },
    },
  );
});

Deno.test("save draft payload requires a version and concurrency timestamp", () => {
  const payload = saveDraftPayloadSchema.parse({
    organization_id: organizationId,
    version_id: versionId,
    expected_updated_at: updatedAt,
    editor_graph: { nodes: [], edges: [] },
  });

  assertEquals(payload.version_id, versionId);
  assertThrows(
    () =>
      saveDraftPayloadSchema.parse({
        organization_id: organizationId,
        version_id: versionId,
        editor_graph: { nodes: [], edges: [] },
      }),
    "expected_updated_at",
  );
});

Deno.test("publish payload rejects invalid identifiers and timestamps", () => {
  assertThrows(
    () =>
      publishDraftPayloadSchema.parse({
        organization_id: "not-a-uuid",
        version_id: versionId,
        expected_updated_at: updatedAt,
      }),
    "organization_id",
  );

  assertThrows(
    () =>
      publishDraftPayloadSchema.parse({
        organization_id: organizationId,
        version_id: versionId,
        expected_updated_at: "yesterday",
      }),
    "expected_updated_at",
  );
});

Deno.test("deployment payloads require an address, published version, and agent", () => {
  const agentId = "34000000-0000-4000-8000-000000000001";
  const deployment = activateDeploymentPayloadSchema.parse({
    organization_id: organizationId,
    organization_address: " 15551234567 ",
    version_id: versionId,
    agent_id: agentId,
  });

  assertEquals(deployment.organization_address, "15551234567");
  assertEquals(deployment.version_id, versionId);
  assertEquals(deployment.agent_id, agentId);
  assertThrows(
    () =>
      deploymentPayloadSchema.parse({
        organization_id: organizationId,
        organization_address: " ",
      }),
    "organization_address",
  );
});

Deno.test("simulation payload keeps local state optional and bounded", () => {
  const payload = simulateFlowPayloadSchema.parse({
    organization_id: organizationId,
    editor_graph: { nodes: [], edges: [] },
    current_node_id: " input-1 ",
    variables: { customer_city: "Lahore" },
    free_text_input: "Lahore",
  });

  assertEquals(payload.current_node_id, "input-1");
  assertEquals(payload.variables, { customer_city: "Lahore" });
  assertThrows(
    () =>
      simulateFlowPayloadSchema.parse({
        organization_id: organizationId,
        editor_graph: { nodes: [], edges: [] },
        free_text_input: "x".repeat(4097),
      }),
    "free_text_input",
  );
});
