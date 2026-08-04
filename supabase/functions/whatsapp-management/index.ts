import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { Context, Hono } from "@hono/hono";
import { cors } from "jsr:@hono/hono/cors";
import { HTTPException } from "jsr:@hono/hono/http-exception";
import * as log from "../_shared/logger.ts";
import { Json } from "../_shared/db_types.ts";
import {
  ApiKeyRow,
  createApiClient,
  createClient,
  createUnsecureClient,
  type Database,
  type TemplateData,
} from "../_shared/supabase.ts";
import {
  createTemplate,
  createTemplateDraft,
  deleteTemplate,
  deleteTemplateDraft,
  deleteTemplateRecord,
  editTemplate,
  editTemplateRecord,
  fetchTemplate,
  listTemplateRecordsPage,
  listTemplates,
  submitTemplateDraft,
  syncTemplates,
  updateTemplateDraft,
} from "./templates.ts";
import { parseTemplateDraftInput } from "../_shared/template_validation.ts";
import {
  deleteSignup,
  performEmbeddedSignup,
  SignupPayload,
} from "./embedded_signup.ts";
import { syncWhatsAppProfile, updateWhatsAppProfile } from "./profile.ts";
import { type User } from "@supabase/supabase-js";
import {
  deleteCampaignMedia,
  proxyCampaignMedia,
  startCampaignWithMediaValidation,
  uploadCampaignMedia,
} from "./campaign_media.ts";
import type { MediaHeaderFormat } from "../_shared/types/whatsapp_template_types.ts";

type TemplatePayload = {
  organization_id: string;
  organization_address: string;
  template?: TemplateData;
};

type TemplateDraftPayload = {
  organization_id: string;
  organization_address: string;
  draft_id?: string;
  template?: unknown;
};

type TemplatePagePayload = {
  organization_id: string;
  page?: number;
  page_size?: number;
  search?: string | null;
  organization_address?: string | null;
  category?: string | null;
  status?: string | null;
};

type TemplateRecordMutationPayload = {
  organization_id: string;
  template?: unknown;
};

type ParsedTemplateMutation = TemplateRecordMutationPayload & {
  draft_id?: string;
  media_file?: File;
};

type AppEnv = {
  Variables: {
    supabase: ReturnType<typeof createClient>;
    user: User;
    token: string;
    apiKey: ApiKeyRow;
  };
};

type OrganizationRole = Database["public"]["Enums"]["role"];

const app = new Hono<AppEnv>();

// CORS middleware
app.use("*", cors());

// Surface thrown errors (and their `cause`) to the client and logs. Hono's
// default handler only serializes an HTTPException's `message`, discarding the
// `cause` where upstream details (e.g. the Graph API error) live.
app.onError((err, c) => {
  if (err instanceof HTTPException) {
    log.error(
      `${c.req.method} ${c.req.path} → ${err.status}: ${err.message}`,
      err.cause,
    );
    return c.json(
      { message: err.message, cause: err.cause as Json },
      err.status,
    );
  }

  log.error(`Unhandled error on ${c.req.method} ${c.req.path}`, err);
  return c.json({ message: "Internal Server Error" }, 500);
});

// Validate user or key (skip for public onboard routes)
app.use("*", async (c, next) => {
  if (c.req.path.endsWith("/onboard")) {
    await next();
    return;
  }

  const token = c.req.header("Authorization")?.replace("Bearer ", "");

  if (!token) {
    throw new HTTPException(401, {
      message: "Missing authorization token",
    });
  }

  c.set("token", token);

  // if token looks like JWT, try user
  if (token.startsWith("eyJ")) {
    const client = createClient(c.req.raw);

    const { data: { user }, error: userError } = await client.auth.getUser();

    if (userError || !user) {
      log.error("Invalid JWT", userError);

      throw new HTTPException(401, {
        message: "Invalid JWT",
        cause: userError,
      });
    }

    c.set("user", user);
    c.set("supabase", client);

    await next();

    return;
  }

  const client = createApiClient(c.req.raw);

  const { data: apiKey, error: apiKeyError } = await client
    .from("api_keys")
    .select()
    .eq("key", token)
    .maybeSingle();

  if (apiKeyError || !apiKey) {
    log.error("Invalid API key", apiKeyError);

    throw new HTTPException(401, {
      message: "Invalid API key",
      cause: apiKeyError,
    });
  }

  c.set("apiKey", apiKey);
  c.set("supabase", client);

  await next();

  return;
});

// Require roles middleware factory
function requireRoles(
  roles: OrganizationRole[],
) {
  return async (c: Context<AppEnv>, next: () => Promise<void>) => {
    const client = c.get("supabase");

    // We must clone the request if we want to read the body in middleware
    // because c.req.json() consumes the stream.
    const request = c.req.raw.clone();
    const contentType = request.headers.get("content-type") || "";
    const organization_id = request.method === "GET"
      ? new URL(request.url).searchParams.get("organization_id")
      : contentType.includes("multipart/form-data")
      ? (await request.formData()).get("organization_id")
      : (await request.json()).organization_id;

    if (typeof organization_id !== "string" || !organization_id) {
      throw new HTTPException(400, {
        message: "Missing organization_id",
      });
    }

    const user = c.get("user");

    if (user) {
      const { error: agentError, data: agent } = await client
        .from("agents")
        .select("organization_id")
        .eq("user_id", user.id)
        .eq("organization_id", organization_id)
        .in("extra->>role", roles)
        .maybeSingle();

      if (agentError || !agent) {
        log.error(
          `User ${user.id} not authorized for organization ${organization_id}. Allowed roles: ${
            roles.join(", ")
          }`,
          agentError,
        );

        throw new HTTPException(403, {
          message:
            `User ${user.id} not authorized for organization ${organization_id}. Allowed roles: ${
              roles.join(", ")
            }`,
          cause: agentError,
        });
      }

      await next();
      return;
    }

    const apiKey = c.get("apiKey")!;

    if (
      organization_id !== apiKey.organization_id || !roles.includes(apiKey.role)
    ) {
      log.error(
        `API key not authorized for organization ${organization_id}. Allowed roles: ${
          roles.join(", ")
        }`,
      );

      throw new HTTPException(403, {
        message:
          `API key not authorized for organization ${organization_id}. Allowed roles: ${
            roles.join(", ")
          }`,
      });
    }

    await next();
  };
}

function parseDraftInput(value: unknown, requireComplete = false) {
  try {
    return parseTemplateDraftInput(value, { requireComplete });
  } catch (error) {
    throw new HTTPException(400, {
      message: error instanceof Error ? error.message : "Template is invalid",
    });
  }
}

async function parseTemplateMutation(
  c: Context<AppEnv>,
): Promise<ParsedTemplateMutation> {
  if (!c.req.header("content-type")?.includes("multipart/form-data")) {
    return await c.req.json<ParsedTemplateMutation>();
  }

  const form = await c.req.formData();
  const organizationId = form.get("organization_id");
  const draftId = form.get("draft_id");
  const templateValue = form.get("template");
  const fileValue = form.get("file");

  if (typeof organizationId !== "string" || !organizationId) {
    throw new HTTPException(400, { message: "Missing organization_id" });
  }
  if (typeof templateValue !== "string" || !templateValue) {
    throw new HTTPException(400, { message: "Missing template" });
  }

  let template: unknown;
  try {
    template = JSON.parse(templateValue);
  } catch {
    throw new HTTPException(400, { message: "Template JSON is invalid" });
  }

  return {
    organization_id: organizationId,
    draft_id: typeof draftId === "string" && draftId ? draftId : undefined,
    template,
    media_file: fileValue instanceof File && fileValue.size > 0
      ? fileValue
      : undefined,
  };
}

function getTemplateId(c: Context<AppEnv>) {
  const templateId = c.req.param("templateId");
  if (!templateId) {
    throw new HTTPException(400, { message: "Missing templateId" });
  }
  return templateId;
}

async function getCurrentAgentId(
  c: Context<AppEnv>,
  organizationId: string,
): Promise<string | null> {
  const user = c.get("user");
  if (!user) return null;

  const { data, error } = await c.get("supabase")
    .from("agents")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("user_id", user.id)
    .maybeSingle();

  if (error || !data) {
    throw new HTTPException(403, {
      message: "Could not resolve the template creator",
      cause: error,
    });
  }

  return data.id;
}

// Templates routes

app.put(
  "/whatsapp-management/templates",
  requireRoles(["member", "supervisor", "admin", "owner"]),
  async (c) => {
    const { organization_id, organization_address, template } = await c.req
      .json<TemplatePayload>();

    const client = c.get("supabase");

    // fetch
    if (template) {
      const templateDetails = await fetchTemplate(
        client,
        organization_id,
        organization_address,
        template,
      );

      return c.json(templateDetails);
    }

    // list
    const templates = await listTemplates(
      client,
      organization_id,
      organization_address,
    );

    return c.json(templates);
  },
);

app.post(
  "/whatsapp-management/templates",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const { organization_id, organization_address, template } = await c.req
      .json<TemplatePayload>();

    const client = c.get("supabase");

    const response = await createTemplate(
      client,
      organization_id,
      organization_address,
      template!,
    );

    return c.json(response);
  },
);

app.patch(
  "/whatsapp-management/templates",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const { organization_id, organization_address, template } = await c.req
      .json<TemplatePayload>();

    const client = c.get("supabase");

    const response = await editTemplate(
      client,
      organization_id,
      organization_address,
      template!,
    );

    return c.json(response);
  },
);

app.delete(
  "/whatsapp-management/templates",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const { organization_id, organization_address, template } = await c.req
      .json<TemplatePayload>();

    const client = c.get("supabase");

    const response = await deleteTemplate(
      client,
      organization_id,
      organization_address,
      template!,
    );

    return c.json(response);
  },
);

app.patch(
  "/whatsapp-management/templates/:templateId",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const payload = await parseTemplateMutation(c);
    return c.json(
      await editTemplateRecord(
        c.get("supabase"),
        payload.organization_id,
        getTemplateId(c),
        parseDraftInput(payload.template, true),
        payload.media_file,
      ),
    );
  },
);

app.delete(
  "/whatsapp-management/templates/:templateId",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const payload = await c.req.json<TemplateRecordMutationPayload>();
    return c.json(
      await deleteTemplateRecord(
        c.get("supabase"),
        payload.organization_id,
        getTemplateId(c),
      ),
    );
  },
);

app.put(
  "/whatsapp-management/templates/page",
  requireRoles(["member", "supervisor", "admin", "owner"]),
  async (c) => {
    const payload = await c.req.json<TemplatePagePayload>();

    return c.json(
      await listTemplateRecordsPage(
        c.get("supabase"),
        payload.organization_id,
        {
          page: payload.page,
          pageSize: payload.page_size,
          search: payload.search,
          organizationAddress: payload.organization_address,
          category: payload.category,
          status: payload.status,
        },
      ),
    );
  },
);

app.post(
  "/whatsapp-management/templates/sync",
  requireRoles(["member", "admin", "owner"]),
  async (c) => {
    const { organization_id, organization_address } = await c.req
      .json<TemplateDraftPayload>();

    if (!organization_address) {
      throw new HTTPException(400, {
        message: "Missing organization_address",
      });
    }

    // Authorization was checked above. The service client is used only for the
    // local upsert so members can refresh readable Meta state without receiving
    // direct write permission on message_templates.
    return c.json(
      await syncTemplates(
        createUnsecureClient(),
        organization_id,
        organization_address,
      ),
    );
  },
);

app.post(
  "/whatsapp-management/template-drafts",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const payload = await c.req.json<TemplateDraftPayload>();
    if (!payload.organization_address) {
      throw new HTTPException(400, {
        message: "Missing organization_address",
      });
    }

    return c.json(
      await createTemplateDraft(
        c.get("supabase"),
        payload.organization_id,
        payload.organization_address,
        await getCurrentAgentId(c, payload.organization_id),
        parseDraftInput(payload.template),
      ),
      201,
    );
  },
);

app.patch(
  "/whatsapp-management/template-drafts",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const payload = await c.req.json<TemplateDraftPayload>();
    if (!payload.draft_id) {
      throw new HTTPException(400, { message: "Missing draft_id" });
    }
    if (!payload.organization_address) {
      throw new HTTPException(400, {
        message: "Missing organization_address",
      });
    }

    return c.json(
      await updateTemplateDraft(
        c.get("supabase"),
        payload.organization_id,
        payload.draft_id,
        payload.organization_address,
        parseDraftInput(payload.template),
      ),
    );
  },
);

app.delete(
  "/whatsapp-management/template-drafts",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const payload = await c.req.json<TemplateDraftPayload>();
    if (!payload.draft_id) {
      throw new HTTPException(400, { message: "Missing draft_id" });
    }

    return c.json(
      await deleteTemplateDraft(
        c.get("supabase"),
        payload.organization_id,
        payload.draft_id,
      ),
    );
  },
);

app.post(
  "/whatsapp-management/template-drafts/submit",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const payload = await parseTemplateMutation(c);
    if (!payload.draft_id) {
      throw new HTTPException(400, { message: "Missing draft_id" });
    }

    return c.json(
      await submitTemplateDraft(
        c.get("supabase"),
        payload.organization_id,
        payload.draft_id,
        parseDraftInput(payload.template, true),
        payload.media_file,
      ),
    );
  },
);

// Campaign media routes

app.post(
  "/whatsapp-management/campaign-media",
  requireRoles(["member", "admin", "owner"]),
  async (c) => {
    const form = await c.req.formData();
    const organizationId = String(form.get("organization_id") || "");
    const organizationAddress = String(form.get("organization_address") || "");
    const format = String(form.get("format") || "") as MediaHeaderFormat;
    const file = form.get("file");
    if (
      !organizationAddress || !["IMAGE", "VIDEO", "DOCUMENT"].includes(format)
    ) {
      throw new HTTPException(400, {
        message: "Campaign media account or format is invalid",
      });
    }
    if (!(file instanceof File)) {
      throw new HTTPException(400, {
        message: "Campaign media file is required",
      });
    }
    return c.json(
      await uploadCampaignMedia(
        c.get("supabase"),
        organizationId,
        organizationAddress,
        format,
        file,
      ),
      201,
    );
  },
);

app.get(
  "/whatsapp-management/campaign-media/:mediaId",
  requireRoles(["member", "admin", "owner"]),
  async (c) => {
    const organizationId = c.req.query("organization_id") || "";
    const organizationAddress = c.req.query("organization_address") || "";
    return await proxyCampaignMedia(
      c.get("supabase"),
      organizationId,
      organizationAddress,
      c.req.param("mediaId")!,
    );
  },
);

app.delete(
  "/whatsapp-management/campaign-media/:mediaId",
  requireRoles(["member", "admin", "owner"]),
  async (c) => {
    const payload = await c.req.json<
      { organization_id: string; organization_address: string }
    >();
    return c.json(
      await deleteCampaignMedia(
        c.get("supabase"),
        payload.organization_id,
        payload.organization_address,
        c.req.param("mediaId")!,
      ),
    );
  },
);

app.post(
  "/whatsapp-management/campaigns/:campaignId/start",
  requireRoles(["member", "admin", "owner"]),
  async (c) => {
    const { organization_id } = await c.req.json<{ organization_id: string }>();
    return c.json(
      await startCampaignWithMediaValidation(
        c.get("supabase"),
        organization_id,
        c.req.param("campaignId")!,
      ),
    );
  },
);

// Business profile routes

app.post(
  "/whatsapp-management/profile/sync",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const { organization_id, organization_address } = await c.req.json<{
      organization_id: string;
      organization_address: string;
    }>();

    if (!organization_address) {
      throw new HTTPException(400, {
        message: "Missing organization_address",
      });
    }

    const client = createUnsecureClient();
    return c.json(
      await syncWhatsAppProfile(
        client,
        organization_id,
        organization_address,
      ),
    );
  },
);

app.patch(
  "/whatsapp-management/profile",
  requireRoles(["admin", "owner"]),
  async (c) => {
    const form = await c.req.formData();
    const client = createUnsecureClient();
    return c.json(await updateWhatsAppProfile(client, form));
  },
);

// Embedded signup routes

app.post("/whatsapp-management/signup", requireRoles(["owner"]), async (c) => {
  const payload = await c.req.json<SignupPayload>();
  log.info("Embedded signup payload", payload);

  // Once the user has been authorized, use the unsecure client to
  // avoid row-level security.
  // Users are not allowed to modify organizations_addresses table.
  const unsecureClient = createUnsecureClient();

  try {
    const address = await performEmbeddedSignup(unsecureClient, payload);

    log.info("Signup completed", {
      organization_id: payload.organization_id,
      address: address.address,
    });

    return c.json(address);
  } catch (error) {
    if (error instanceof HTTPException) {
      log.error(error.message, error);

      await unsecureClient
        .from("logs")
        .insert({
          organization_id: payload.organization_id,
          category: "signup",
          service: "whatsapp",
          level: "error",
          message: error.message,
          metadata: error.cause as Json,
        })
        .throwOnError();
    } else {
      log.error("Embedded signup failed", error);
    }

    throw error;
  }
});

app.delete(
  "/whatsapp-management/signup",
  requireRoles(["owner"]),
  async (c) => {
    const payload = await c.req.json<{
      phone_number_id: string;
      organization_id: string;
    }>();
    log.info("Embedded signup delete payload", payload);

    // Once the user has been authorized, use the unsecure client to
    // avoid row-level security.
    // Users are not allowed to modify organizations_addresses table.
    const unsecureClient = createUnsecureClient();

    const address = await deleteSignup(
      unsecureClient,
      payload,
    );

    return c.json(address);
  },
);

// Public onboard routes (no auth required, token-based)

app.get("/whatsapp-management/onboard", async (c) => {
  const token = c.req.query("token");

  if (!token) {
    throw new HTTPException(400, { message: "Missing 'token' query param" });
  }

  const client = createUnsecureClient();

  const { data, error } = await client
    .from("onboarding_tokens")
    .select("id, organization_id, organizations(name)")
    .eq("id", token)
    .eq("service", "whatsapp")
    .eq("status", "active")
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();

  if (error || !data) {
    return c.json({ valid: false });
  }

  return c.json({
    valid: true,
    organization_name: data.organizations?.name,
  });
});

app.post("/whatsapp-management/onboard", async (c) => {
  const body = await c.req.json<{
    token: string;
    code: string;
    application_id?: string;
    phone_number_id?: string;
    waba_id?: string;
    business_id?: string;
    flow_type?: "only_waba" | "new_phone_number" | "existing_phone_number";
  }>();

  if (!body.token) {
    throw new HTTPException(400, { message: "Missing 'token' body param" });
  }

  log.info("Public onboard payload", body);

  const client = createUnsecureClient();

  // Read the token once and validate it in code — don't consume it; the link is
  // marked used only after the account connects (below). A single read also lets
  // us log exactly why a token was rejected when an onboard link "was used" but
  // nothing happened on our side.
  const { data: tokenData, error: tokenError } = await client
    .from("onboarding_tokens")
    .select(
      "status, service, expires_at, organization_id, callback_url, verify_token",
    )
    .eq("id", body.token)
    .maybeSingle();

  const reason = tokenError
    ? `db error: ${tokenError.message}`
    : !tokenData
    ? "token not found"
    : tokenData.service !== "whatsapp"
    ? `service mismatch (token is '${tokenData.service}')`
    : tokenData.status !== "active"
    ? `not active (status '${tokenData.status}')`
    : new Date(tokenData.expires_at) <= new Date()
    ? `expired at ${tokenData.expires_at}`
    : null;

  if (reason || !tokenData) {
    log.warn("Onboard token rejected", {
      token: body.token,
      reason,
      organization_id: tokenData?.organization_id,
    });

    throw new HTTPException(400, {
      message: "Invalid or expired onboarding token",
    });
  }

  log.info("Onboard token validated", {
    token: body.token,
    organization_id: tokenData.organization_id,
  });

  const payload: SignupPayload = {
    code: body.code,
    application_id: body.application_id,
    organization_id: tokenData.organization_id,
    phone_number_id: body.phone_number_id,
    waba_id: body.waba_id,
    business_id: body.business_id,
    flow_type: body.flow_type,
    callback_url: tokenData.callback_url ?? undefined,
    verify_token: tokenData.verify_token ?? undefined,
  };

  // Connect the account, then mark the link used on success. Same try/catch as
  // the authenticated /signup route: on failure record it (with the Meta cause)
  // to public.logs so the org's tech-provider can self-debug a bad
  // callback_url/verify_token — not just OpenBSP operators reading stdout. The
  // token stays active on failure, so the customer can retry.
  try {
    const address = await performEmbeddedSignup(client, payload);

    // Connected — mark the link used. This is the function's authoritative
    // status write, derived from the actual onboarding outcome. The status guard
    // keeps it idempotent under a double submit.
    await client
      .from("onboarding_tokens")
      .update({ status: "used", used_at: new Date().toISOString() })
      .eq("id", body.token)
      .eq("status", "active");

    log.info("Onboard completed", {
      token: body.token,
      organization_id: tokenData.organization_id,
      address: address.address,
    });

    return c.json(address);
  } catch (error) {
    if (error instanceof HTTPException) {
      log.error(error.message, error);
      await client
        .from("logs")
        .insert({
          organization_id: tokenData.organization_id,
          category: "signup",
          service: "whatsapp",
          level: "error",
          message: error.message,
          metadata: error.cause as Json,
        })
        .throwOnError();
    } else {
      log.error("Embedded signup failed", error);
    }

    throw error;
  }
});

Deno.serve(app.fetch);
