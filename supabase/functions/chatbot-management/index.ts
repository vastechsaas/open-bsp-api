import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { type Context, Hono } from "@hono/hono";
import { cors } from "jsr:@hono/hono/cors";
import { HTTPException } from "jsr:@hono/hono/http-exception";
import { type SupabaseClient, type User } from "@supabase/supabase-js";
import { z } from "zod";
import * as log from "../_shared/logger.ts";
import {
  compileFlowDefinition,
  type FlowDefinitionV1,
} from "../_shared/chatbot/mod.ts";
import {
  type ApiKeyRow,
  createApiClient,
  createClient,
  createUnsecureClient,
  type Database,
  type Json,
} from "../_shared/supabase.ts";
import {
  activateDeploymentPayloadSchema,
  createFlowPayloadSchema,
  createWebhookCredentialPayloadSchema,
  deploymentPayloadSchema,
  duplicateFlowPayloadSchema,
  organizationPayloadSchema,
  publishDraftPayloadSchema,
  renameFlowPayloadSchema,
  saveDraftPayloadSchema,
  simulateFlowPayloadSchema,
  validateDraftPayloadSchema,
} from "./payload.ts";
import {
  assignedHumanAgentIds,
  findUnavailableAgentIssues,
} from "./agent_references.ts";
import { simulateChatbotFlow } from "./simulation.ts";

type AppEnv = {
  Variables: {
    supabase: SupabaseClient<Database>;
    user: User;
    apiKey: ApiKeyRow;
    actorAgentId: string | null;
  };
};

type DatabaseError = {
  code?: string;
  message?: string;
  details?: string;
  hint?: string;
};

type OrganizationRole = Database["public"]["Enums"]["role"];

const app = new Hono<AppEnv>();

app.use("*", cors());

app.onError((error, c) => {
  if (error instanceof z.ZodError) {
    return c.json({
      message: "Invalid request payload",
      issues: error.issues,
    }, 400);
  }

  if (error instanceof HTTPException) {
    log.error(
      `${c.req.method} ${c.req.path} -> ${error.status}: ${error.message}`,
      error.cause,
    );
    return c.json({
      message: error.message,
      cause: error.cause as Json,
    }, error.status);
  }

  log.error(`Unhandled error on ${c.req.method} ${c.req.path}`, error);
  return c.json({ message: "Internal Server Error" }, 500);
});

app.use("*", async (c, next) => {
  const token = c.req.header("Authorization")?.replace("Bearer ", "");

  if (!token) {
    throw new HTTPException(401, {
      message: "Missing authorization token",
    });
  }

  if (token.startsWith("eyJ")) {
    const client = createClient(c.req.raw);
    const { data: { user }, error } = await client.auth.getUser();

    if (error || !user) {
      throw new HTTPException(401, {
        message: "Invalid JWT",
        cause: error,
      });
    }

    c.set("user", user);
    c.set("supabase", client);
    await next();
    return;
  }

  const client = createApiClient(c.req.raw);
  const { data: apiKey, error } = await client
    .from("api_keys")
    .select()
    .eq("key", token)
    .maybeSingle();

  if (error || !apiKey) {
    throw new HTTPException(401, {
      message: "Invalid API key",
      cause: error,
    });
  }

  c.set("apiKey", apiKey);
  c.set("supabase", client);
  await next();
});

function requireAdmin(
  c: Context<AppEnv>,
  next: () => Promise<void>,
): Promise<void> {
  return authorizeOrganization(c, next, ["admin", "owner"]);
}

function requireMember(
  c: Context<AppEnv>,
  next: () => Promise<void>,
): Promise<void> {
  return authorizeOrganization(c, next, ["member", "admin", "owner"]);
}

async function authorizeOrganization(
  c: Context<AppEnv>,
  next: () => Promise<void>,
  roles: OrganizationRole[],
): Promise<void> {
  const organizationId = c.req.method === "GET"
    ? organizationPayloadSchema.parse({
      organization_id: c.req.query("organization_id"),
    }).organization_id
    : organizationPayloadSchema.parse(
      await c.req.raw.clone().json(),
    ).organization_id;

  const user = c.get("user");
  if (user) {
    const { data: agent, error } = await c.get("supabase")
      .from("agents")
      .select("id")
      .eq("user_id", user.id)
      .eq("organization_id", organizationId)
      .in("extra->>role", roles)
      .maybeSingle();

    if (error || !agent) {
      throw new HTTPException(403, {
        message: "Administrator access is required for this organization",
        cause: error,
      });
    }

    c.set("actorAgentId", agent.id);
    await next();
    return;
  }

  const apiKey = c.get("apiKey");
  if (
    !apiKey ||
    apiKey.organization_id !== organizationId ||
    !roles.includes(apiKey.role)
  ) {
    throw new HTTPException(403, {
      message: "Administrator access is required for this organization",
    });
  }

  c.set("actorAgentId", null);
  await next();
}

function throwDatabaseError(error: DatabaseError, fallback: string): never {
  if (error.code === "23505") {
    throw new HTTPException(409, {
      message: "A chatbot flow with this name already exists",
      cause: error,
    });
  }

  if (error.code === "P0002") {
    throw new HTTPException(404, {
      message: error.message ?? fallback,
      cause: error,
    });
  }

  if (["22023", "23503", "23514"].includes(error.code ?? "")) {
    throw new HTTPException(400, {
      message: error.message ?? fallback,
      cause: error,
    });
  }

  throw new HTTPException(500, {
    message: fallback,
    cause: error,
  });
}

function serviceClient(): SupabaseClient<Database> {
  return createUnsecureClient();
}

async function unavailableAgentIssues(
  client: SupabaseClient<Database>,
  organizationId: string,
  definition: FlowDefinitionV1,
) {
  const referencedIds = assignedHumanAgentIds(definition);
  if (referencedIds.length === 0) return [];

  const { data, error } = await client
    .from("agents")
    .select("id, user_id, extra")
    .eq("organization_id", organizationId)
    .eq("ai", false)
    .in("id", referencedIds);

  if (error) {
    throwDatabaseError(error, "Unable to validate chatbot handoff agents");
  }

  const availableIds = new Set(
    data.filter((agent) => {
      if (!agent.user_id) return false;
      const extra = agent.extra;
      if (!extra || typeof extra !== "object" || Array.isArray(extra)) {
        return true;
      }
      const invitation = "invitation" in extra ? extra.invitation : undefined;
      return !invitation ||
        typeof invitation !== "object" ||
        Array.isArray(invitation) ||
        invitation.status === "accepted";
    }).map((agent) => agent.id),
  );

  return findUnavailableAgentIssues(definition, availableIds);
}

async function unavailableWebhookCredentialIssues(
  client: SupabaseClient<Database>,
  organizationId: string,
  definition: FlowDefinitionV1,
) {
  const references = [
    ...new Set(
      definition.nodes.flatMap((node) =>
        node.type === "webhook" && node.config.secret_id
          ? [node.config.secret_id]
          : []
      ),
    ),
  ];
  if (references.length === 0) return [];

  const { data, error } = await client
    .from("chatbot_webhook_credentials")
    .select("id")
    .eq("organization_id", organizationId)
    .in("id", references);
  if (error) {
    throwDatabaseError(error, "Unable to validate webhook credentials");
  }

  const available = new Set(data.map((credential) => credential.id));
  return definition.nodes.flatMap((node, index) =>
    node.type === "webhook" &&
      node.config.secret_id &&
      !available.has(node.config.secret_id)
      ? [{
        code: "webhook_credential_unavailable",
        path: ["nodes", index, "data", "config", "secret_id"],
        message: "The selected webhook credential is unavailable",
        node_id: node.id,
      }]
      : []
  );
}

async function externalReferenceIssues(
  client: SupabaseClient<Database>,
  organizationId: string,
  definition: FlowDefinitionV1,
) {
  return [
    ...await unavailableAgentIssues(client, organizationId, definition),
    ...await unavailableWebhookCredentialIssues(
      client,
      organizationId,
      definition,
    ),
  ];
}

function flowId(c: Context<AppEnv>): string {
  const value = c.req.param("flowId");

  if (!value) {
    throw new HTTPException(400, { message: "Missing chatbot flow ID" });
  }

  return z.string().uuid().parse(value);
}

app.post("/chatbot-management/flows", requireAdmin, async (c) => {
  const payload = createFlowPayloadSchema.parse(await c.req.json());
  const { data, error } = await serviceClient().rpc(
    "create_chatbot_flow_draft",
    {
      p_organization_id: payload.organization_id,
      p_name: payload.name,
      ...(c.get("actorAgentId")
        ? { p_created_by: c.get("actorAgentId")! }
        : {}),
    },
  );

  if (error) throwDatabaseError(error, "Unable to create chatbot flow");

  return c.json(data[0], 201);
});

app.get(
  "/chatbot-management/webhook-credentials",
  requireAdmin,
  async (c) => {
    const organizationId = c.req.query("organization_id")!;
    const { data, error } = await serviceClient()
      .from("chatbot_webhook_credentials")
      .select("id, name, created_at, updated_at")
      .eq("organization_id", organizationId)
      .order("name");
    if (error) {
      throwDatabaseError(error, "Unable to load webhook credentials");
    }
    return c.json({ credentials: data });
  },
);

app.post(
  "/chatbot-management/webhook-credentials",
  requireAdmin,
  async (c) => {
    const payload = createWebhookCredentialPayloadSchema.parse(
      await c.req.json(),
    );
    const { data, error } = await serviceClient().rpc(
      "create_chatbot_webhook_credential",
      {
        p_organization_id: payload.organization_id,
        p_name: payload.name,
        p_headers: payload.headers,
        ...(c.get("actorAgentId")
          ? { p_created_by: c.get("actorAgentId")! }
          : {}),
      },
    );
    if (error) {
      throwDatabaseError(error, "Unable to create webhook credential");
    }
    return c.json({ credential: data[0] }, 201);
  },
);

app.delete(
  "/chatbot-management/webhook-credentials/:credentialId",
  requireAdmin,
  async (c) => {
    const organizationId = organizationPayloadSchema.parse(
      await c.req.json(),
    ).organization_id;
    const credentialId = z.string().uuid().parse(c.req.param("credentialId"));
    const { data, error } = await serviceClient()
      .from("chatbot_webhook_credentials")
      .delete()
      .eq("organization_id", organizationId)
      .eq("id", credentialId)
      .select("id")
      .maybeSingle();
    if (error) {
      throwDatabaseError(error, "Unable to delete webhook credential");
    }
    if (!data) {
      throw new HTTPException(404, {
        message: "Webhook credential not found",
      });
    }
    return c.json({ deleted: true });
  },
);

app.patch("/chatbot-management/flows/:flowId", requireAdmin, async (c) => {
  const payload = renameFlowPayloadSchema.parse(await c.req.json());
  const { data, error } = await serviceClient()
    .from("chatbot_flows")
    .update({ name: payload.name })
    .eq("organization_id", payload.organization_id)
    .eq("id", flowId(c))
    .select("id, name, status, updated_at")
    .maybeSingle();

  if (error) throwDatabaseError(error, "Unable to rename chatbot flow");
  if (!data) {
    throw new HTTPException(404, { message: "Chatbot flow not found" });
  }

  return c.json(data);
});

app.post(
  "/chatbot-management/flows/:flowId/duplicate",
  requireAdmin,
  async (c) => {
    const payload = duplicateFlowPayloadSchema.parse(await c.req.json());
    const { data, error } = await serviceClient().rpc(
      "duplicate_chatbot_flow_draft",
      {
        p_organization_id: payload.organization_id,
        p_source_flow_id: flowId(c),
        p_name: payload.name,
        ...(c.get("actorAgentId")
          ? { p_created_by: c.get("actorAgentId")! }
          : {}),
      },
    );

    if (error) throwDatabaseError(error, "Unable to duplicate chatbot flow");

    return c.json(data[0], 201);
  },
);

app.post(
  "/chatbot-management/flows/:flowId/archive",
  requireAdmin,
  async (c) => {
    const payload = organizationPayloadSchema.parse(await c.req.json());
    const { data, error } = await serviceClient()
      .from("chatbot_flows")
      .update({
        status: "archived",
        archived_at: new Date().toISOString(),
      })
      .eq("organization_id", payload.organization_id)
      .eq("id", flowId(c))
      .select("id, status, archived_at, updated_at")
      .maybeSingle();

    if (error) throwDatabaseError(error, "Unable to archive chatbot flow");
    if (!data) {
      throw new HTTPException(404, { message: "Chatbot flow not found" });
    }

    return c.json(data);
  },
);

app.post(
  "/chatbot-management/flows/:flowId/restore",
  requireAdmin,
  async (c) => {
    const payload = organizationPayloadSchema.parse(await c.req.json());
    const { data, error } = await serviceClient()
      .from("chatbot_flows")
      .update({ status: "active", archived_at: null })
      .eq("organization_id", payload.organization_id)
      .eq("id", flowId(c))
      .select("id, status, archived_at, updated_at")
      .maybeSingle();

    if (error) throwDatabaseError(error, "Unable to restore chatbot flow");
    if (!data) {
      throw new HTTPException(404, { message: "Chatbot flow not found" });
    }

    return c.json(data);
  },
);

app.get(
  "/chatbot-management/flows/:flowId/draft",
  requireAdmin,
  async (c) => {
    const organizationId = c.req.query("organization_id")!;
    const { data, error } = await serviceClient()
      .from("chatbot_flow_versions")
      .select(
        "id, flow_id, version, status, editor_graph, created_at, updated_at",
      )
      .eq("organization_id", organizationId)
      .eq("flow_id", flowId(c))
      .eq("status", "draft")
      .maybeSingle();

    if (error) throwDatabaseError(error, "Unable to load chatbot draft");
    if (!data) {
      throw new HTTPException(404, { message: "Chatbot draft not found" });
    }

    return c.json(data);
  },
);

app.put(
  "/chatbot-management/flows/:flowId/draft",
  requireAdmin,
  async (c) => {
    const payload = saveDraftPayloadSchema.parse(await c.req.json());
    const client = serviceClient();
    const { data, error } = await client
      .from("chatbot_flow_versions")
      .update({ editor_graph: payload.editor_graph as Json })
      .eq("organization_id", payload.organization_id)
      .eq("flow_id", flowId(c))
      .eq("id", payload.version_id)
      .eq("status", "draft")
      .eq("updated_at", payload.expected_updated_at)
      .select(
        "id, flow_id, version, status, editor_graph, created_at, updated_at",
      )
      .maybeSingle();

    if (error) throwDatabaseError(error, "Unable to save chatbot draft");
    if (data) return c.json(data);

    const { data: current, error: currentError } = await client
      .from("chatbot_flow_versions")
      .select("id, updated_at")
      .eq("organization_id", payload.organization_id)
      .eq("flow_id", flowId(c))
      .eq("id", payload.version_id)
      .eq("status", "draft")
      .maybeSingle();

    if (currentError) {
      throwDatabaseError(currentError, "Unable to inspect chatbot draft");
    }
    if (!current) {
      throw new HTTPException(404, { message: "Chatbot draft not found" });
    }

    return c.json({
      message: "Chatbot draft has changed since it was loaded",
      current_updated_at: current.updated_at,
    }, 409);
  },
);

app.post(
  "/chatbot-management/flows/:flowId/validate",
  requireAdmin,
  async (c) => {
    const payload = validateDraftPayloadSchema.parse(await c.req.json());
    const result = compileFlowDefinition(payload.editor_graph);

    if (!result.ok) {
      return c.json({ valid: false, issues: result.issues });
    }

    const issues = await externalReferenceIssues(
      serviceClient(),
      payload.organization_id,
      result.definition,
    );
    return issues.length > 0
      ? c.json({ valid: false, issues })
      : c.json({ valid: true, definition: result.definition });
  },
);

app.post(
  "/chatbot-management/flows/:flowId/simulate",
  requireAdmin,
  async (c) => {
    const payload = simulateFlowPayloadSchema.parse(await c.req.json());
    const { data: flow, error } = await serviceClient()
      .from("chatbot_flows")
      .select("id")
      .eq("organization_id", payload.organization_id)
      .eq("id", flowId(c))
      .maybeSingle();

    if (error) {
      throwDatabaseError(error, "Unable to verify chatbot flow");
    }
    if (!flow) {
      throw new HTTPException(404, { message: "Chatbot flow not found" });
    }

    const compiled = compileFlowDefinition(payload.editor_graph);
    if (!compiled.ok) {
      return c.json({ valid: false, issues: compiled.issues });
    }
    const agentIssues = await externalReferenceIssues(
      serviceClient(),
      payload.organization_id,
      compiled.definition,
    );
    if (agentIssues.length > 0) {
      return c.json({ valid: false, issues: agentIssues });
    }

    const result = await simulateChatbotFlow(payload.editor_graph, {
      current_node_id: payload.current_node_id,
      variables: payload.variables,
      free_text_input: payload.free_text_input,
      option_input: payload.option_input,
      webhook_mocks: payload.webhook_mocks,
    });

    return c.json(result);
  },
);

app.post(
  "/chatbot-management/flows/:flowId/publish",
  requireAdmin,
  async (c) => {
    const payload = publishDraftPayloadSchema.parse(await c.req.json());
    const client = serviceClient();
    const { data: draft, error: draftError } = await client
      .from("chatbot_flow_versions")
      .select("id, editor_graph, updated_at")
      .eq("organization_id", payload.organization_id)
      .eq("flow_id", flowId(c))
      .eq("id", payload.version_id)
      .eq("status", "draft")
      .maybeSingle();

    if (draftError) {
      throwDatabaseError(draftError, "Unable to load chatbot draft");
    }
    if (!draft) {
      throw new HTTPException(404, { message: "Chatbot draft not found" });
    }
    if (draft.updated_at !== payload.expected_updated_at) {
      return c.json({
        message: "Chatbot draft has changed since it was loaded",
        current_updated_at: draft.updated_at,
      }, 409);
    }

    const compiled = compileFlowDefinition(draft.editor_graph);
    if (!compiled.ok) {
      return c.json({
        message: "Chatbot draft is invalid",
        valid: false,
        issues: compiled.issues,
      }, 422);
    }

    const agentIssues = await externalReferenceIssues(
      client,
      payload.organization_id,
      compiled.definition,
    );
    if (agentIssues.length > 0) {
      return c.json({
        message: "Chatbot draft has unavailable handoff agents",
        valid: false,
        issues: agentIssues,
      }, 422);
    }

    const { data, error } = await client.rpc(
      "publish_chatbot_flow_draft",
      {
        p_organization_id: payload.organization_id,
        p_flow_id: flowId(c),
        p_version_id: payload.version_id,
        p_expected_updated_at: payload.expected_updated_at,
        p_definition: compiled.definition as unknown as Json,
        ...(c.get("actorAgentId")
          ? { p_created_by: c.get("actorAgentId")! }
          : {}),
      },
    );

    if (error) throwDatabaseError(error, "Unable to publish chatbot draft");

    const result = data[0];
    if (!result || result.outcome === "not_found") {
      throw new HTTPException(404, { message: "Chatbot draft not found" });
    }
    if (result.outcome === "conflict") {
      return c.json({
        message: "Chatbot draft has changed since it was loaded",
        current_updated_at: result.draft_updated_at,
      }, 409);
    }

    return c.json({ valid: true, ...result });
  },
);

app.get(
  "/chatbot-management/flows/:flowId/deployments",
  requireMember,
  async (c) => {
    const payload = organizationPayloadSchema.parse({
      organization_id: c.req.query("organization_id"),
    });
    const { data, error } = await serviceClient()
      .from("chatbot_flow_deployments")
      .select()
      .eq("organization_id", payload.organization_id)
      .eq("flow_id", flowId(c))
      .order("organization_address");

    if (error) {
      throwDatabaseError(error, "Unable to load chatbot deployments");
    }

    return c.json({ deployments: data });
  },
);

app.put(
  "/chatbot-management/flows/:flowId/deployment",
  requireAdmin,
  async (c) => {
    const payload = activateDeploymentPayloadSchema.parse(await c.req.json());
    const client = serviceClient();
    const { data: runtimeAgentId, error: runtimeAgentError } = await client.rpc(
      "ensure_chatbot_runtime_agent",
      { p_organization_id: payload.organization_id },
    );

    if (runtimeAgentError || !runtimeAgentId) {
      throwDatabaseError(
        runtimeAgentError ?? {},
        "Unable to resolve chatbot runtime identity",
      );
    }

    const activatedAt = new Date().toISOString();
    const { data, error } = await client
      .from("chatbot_flow_deployments")
      .upsert({
        organization_id: payload.organization_id,
        organization_address: payload.organization_address,
        flow_id: flowId(c),
        flow_version_id: payload.version_id,
        agent_id: runtimeAgentId,
        activated_by: c.get("actorAgentId"),
        activated_at: activatedAt,
      }, { onConflict: "organization_id,organization_address" })
      .select()
      .single();

    if (error) {
      throwDatabaseError(error, "Unable to activate chatbot deployment");
    }

    return c.json({ deployment: data });
  },
);

app.delete(
  "/chatbot-management/flows/:flowId/deployment",
  requireAdmin,
  async (c) => {
    const payload = deploymentPayloadSchema.parse(await c.req.json());
    const { data, error } = await serviceClient()
      .from("chatbot_flow_deployments")
      .delete()
      .eq("organization_id", payload.organization_id)
      .eq("organization_address", payload.organization_address)
      .eq("flow_id", flowId(c))
      .select("organization_address")
      .maybeSingle();

    if (error) {
      throwDatabaseError(error, "Unable to deactivate chatbot deployment");
    }
    if (!data) {
      throw new HTTPException(404, {
        message: "Chatbot deployment not found",
      });
    }

    return c.json({ deactivated: true });
  },
);

Deno.serve(app.fetch);
