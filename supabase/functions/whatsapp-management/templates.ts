import type {
  Database,
  Json,
  TemplateData,
  TemplateDraftInput,
} from "../_shared/supabase.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../_shared/logger.ts";
import { HTTPException } from "jsr:@hono/hono/http-exception";
import { ContentfulStatusCode } from "jsr:@hono/hono/utils/http-status";

const API_VERSION = "v24.0";
const DEFAULT_ACCESS_TOKEN = Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") ||
  "";

export type MetaTemplateListResponse = {
  data: TemplateData[];
  paging?: {
    cursors?: { before?: string; after?: string };
    next?: string;
    previous?: string;
  };
};

export type TemplatePageParams = {
  page?: number;
  pageSize?: number;
  search?: string | null;
  organizationAddress?: string | null;
  category?: string | null;
  status?: string | null;
};

const EDITABLE_SUBMITTED_TEMPLATE_STATUSES = new Set([
  "pending",
  "approved",
  "rejected",
]);

export function isEditableSubmittedTemplateStatus(status: string) {
  return EDITABLE_SUBMITTED_TEMPLATE_STATUSES.has(status.toLowerCase());
}

export function buildMetaTemplateDeleteUrl(
  wabaId: string,
  templateId: string,
  templateName: string,
) {
  const url = new URL(
    `https://graph.facebook.com/${API_VERSION}/${wabaId}/message_templates`,
  );
  url.searchParams.set("hsm_id", templateId);
  url.searchParams.set("name", templateName);
  return url;
}

async function getBusinessCredentials(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
): Promise<{ waba_id: string; access_token: string }> {
  const { data, error } = await client
    .from("organizations_addresses")
    .select("extra->>waba_id, extra->>access_token")
    .eq("organization_id", organization_id)
    .eq("address", organization_address)
    .eq("service", "whatsapp")
    .single();

  if (error || !data) {
    log.error("Could not fetch business access token", error);
    throw new HTTPException(403, {
      message: "Could not fetch business access token",
      cause: error,
    });
  }

  const access_token = data.access_token || DEFAULT_ACCESS_TOKEN;

  if (!data.waba_id || !access_token) {
    throw new HTTPException(422, {
      message: "WhatsApp account credentials are not configured",
    });
  }

  return { waba_id: data.waba_id, access_token };
}

async function readMetaResponse<T>(
  response: Response,
  message: string,
): Promise<T> {
  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new HTTPException(response.status as ContentfulStatusCode, {
      message,
      cause: body,
    });
  }

  return body as T;
}

async function fetchMetaTemplatesPage(
  url: string,
  accessToken: string,
): Promise<MetaTemplateListResponse> {
  const response = await fetch(url, {
    method: "GET",
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  return await readMetaResponse<MetaTemplateListResponse>(
    response,
    "Could not fetch templates",
  );
}

export async function listTemplates(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
): Promise<MetaTemplateListResponse> {
  const { waba_id, access_token } = await getBusinessCredentials(
    client,
    organization_id,
    organization_address,
  );

  const fields = [
    "id",
    "name",
    "status",
    "category",
    "language",
    "components",
    "rejected_reason",
  ].join(",");
  const url = new URL(
    `https://graph.facebook.com/${API_VERSION}/${waba_id}/message_templates`,
  );
  url.searchParams.set("fields", fields);
  url.searchParams.set("limit", "100");

  return await fetchMetaTemplatesPage(url.toString(), access_token);
}

async function listAllTemplates(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
): Promise<TemplateData[]> {
  const { waba_id, access_token } = await getBusinessCredentials(
    client,
    organization_id,
    organization_address,
  );
  const fields = [
    "id",
    "name",
    "status",
    "category",
    "language",
    "components",
    "rejected_reason",
  ].join(",");
  const firstUrl = new URL(
    `https://graph.facebook.com/${API_VERSION}/${waba_id}/message_templates`,
  );
  firstUrl.searchParams.set("fields", fields);
  firstUrl.searchParams.set("limit", "100");

  const templates: TemplateData[] = [];
  let nextUrl: string | undefined = firstUrl.toString();
  let pageCount = 0;

  while (nextUrl && pageCount < 50) {
    const page = await fetchMetaTemplatesPage(nextUrl, access_token);
    templates.push(...page.data);
    nextUrl = page.paging?.next;
    pageCount++;
  }

  return templates;
}

export async function fetchTemplate(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
  template: TemplateData,
): Promise<TemplateData> {
  const { access_token } = await getBusinessCredentials(
    client,
    organization_id,
    organization_address,
  );

  const response = await fetch(
    `https://graph.facebook.com/${API_VERSION}/${template.id}`,
    {
      method: "GET",
      headers: { Authorization: `Bearer ${access_token}` },
    },
  );

  return await readMetaResponse<TemplateData>(
    response,
    "Could not fetch template",
  );
}

async function submitTemplateToMeta(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
  template: TemplateDraftInput,
): Promise<{ id: string; status: string; category: string }> {
  const { waba_id, access_token } = await getBusinessCredentials(
    client,
    organization_id,
    organization_address,
  );

  const response = await fetch(
    `https://graph.facebook.com/${API_VERSION}/${waba_id}/message_templates`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: template.name,
        category: template.category,
        language: template.language,
        components: template.components,
        allow_category_change: true,
      }),
    },
  );

  return await readMetaResponse(
    response,
    "Could not create template",
  );
}

export async function createTemplate(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
  template: TemplateData,
): Promise<{ id: string; status: string; category: string }> {
  return await submitTemplateToMeta(
    client,
    organization_id,
    organization_address,
    template,
  );
}

export async function editTemplate(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
  template: TemplateData,
): Promise<{ success: boolean }> {
  const { access_token } = await getBusinessCredentials(
    client,
    organization_id,
    organization_address,
  );

  const { category, components } = template;
  const response = await fetch(
    `https://graph.facebook.com/${API_VERSION}/${template.id}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ category, components }),
    },
  );

  return await readMetaResponse(response, "Could not update template");
}

export async function deleteTemplate(
  client: SupabaseClient<Database>,
  organization_id: string,
  organization_address: string,
  template: TemplateData,
): Promise<{ success: boolean }> {
  const { waba_id, access_token } = await getBusinessCredentials(
    client,
    organization_id,
    organization_address,
  );
  const url = buildMetaTemplateDeleteUrl(waba_id, template.id, template.name);

  const response = await fetch(url, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${access_token}` },
  });

  return await readMetaResponse(response, "Could not delete template");
}

async function loadTemplateRecord(
  client: SupabaseClient<Database>,
  organizationId: string,
  templateId: string,
) {
  const { data, error } = await client
    .from("message_templates")
    .select()
    .eq("organization_id", organizationId)
    .eq("id", templateId)
    .maybeSingle();

  if (error) {
    throw new HTTPException(400, {
      message: "Could not load template",
      cause: error,
    });
  }
  if (!data) {
    throw new HTTPException(404, { message: "Template not found" });
  }

  return data;
}

function asMetaTemplate(
  record: Awaited<ReturnType<typeof loadTemplateRecord>>,
  template: TemplateDraftInput,
): TemplateData {
  return {
    id: record.external_id!,
    name: record.name,
    language: record.language,
    status: record.status.toUpperCase() as TemplateData["status"],
    category: template.category,
    components: template.components,
  };
}

export async function editTemplateRecord(
  client: SupabaseClient<Database>,
  organizationId: string,
  templateId: string,
  template: TemplateDraftInput,
) {
  const record = await loadTemplateRecord(client, organizationId, templateId);

  if (
    !record.external_id ||
    !isEditableSubmittedTemplateStatus(record.status)
  ) {
    throw new HTTPException(409, {
      message: "Template cannot be edited in its current status",
    });
  }

  const metaTemplate = asMetaTemplate(record, template);
  await editTemplate(
    client,
    organizationId,
    record.organization_address,
    metaTemplate,
  );

  let remoteTemplate: TemplateData | null = null;
  let syncPending = false;
  try {
    remoteTemplate = await fetchTemplate(
      client,
      organizationId,
      record.organization_address,
      metaTemplate,
    );
  } catch (error) {
    syncPending = true;
    log.warn("Template was edited but its Meta state could not be refreshed", {
      organizationId,
      templateId,
      error,
    });
  }

  const { data, error } = await client
    .from("message_templates")
    .update({
      category: (remoteTemplate?.category || template.category).toLowerCase(),
      components:
        (remoteTemplate?.components || template.components) as unknown as Json,
      ...(remoteTemplate
        ? {
          status: remoteTemplate.status.toLowerCase(),
          rejection_reason: remoteTemplate.rejected_reason || null,
          synced_at: new Date().toISOString(),
        }
        : { synced_at: null }),
    })
    .eq("organization_id", organizationId)
    .eq("id", templateId)
    .eq("external_id", record.external_id)
    .select()
    .maybeSingle();

  if (error || !data) {
    throw new HTTPException(500, {
      message: "Template was edited on Meta but could not be saved locally",
      cause: error,
    });
  }

  return { template: data, sync_pending: syncPending };
}

export async function deleteTemplateRecord(
  client: SupabaseClient<Database>,
  organizationId: string,
  templateId: string,
) {
  const record = await loadTemplateRecord(client, organizationId, templateId);

  if (
    !record.external_id ||
    !isEditableSubmittedTemplateStatus(record.status)
  ) {
    throw new HTTPException(409, {
      message: "Template cannot be deleted in its current status",
    });
  }

  const { data: claimed, error: claimError } = await client
    .from("message_templates")
    .update({ status: "pending_deletion" })
    .eq("organization_id", organizationId)
    .eq("id", templateId)
    .eq("status", record.status)
    .select("id")
    .maybeSingle();

  if (claimError) {
    throw new HTTPException(400, {
      message: "Could not prepare template deletion",
      cause: claimError,
    });
  }
  if (!claimed) {
    throw new HTTPException(409, {
      message: "Template deletion is already in progress",
    });
  }

  try {
    await deleteTemplate(
      client,
      organizationId,
      record.organization_address,
      asMetaTemplate(record, {
        name: record.name,
        language: record.language,
        category: record.category
          .toUpperCase() as TemplateDraftInput["category"],
        components: record
          .components as unknown as TemplateDraftInput["components"],
      }),
    );
  } catch (error) {
    const { error: restoreError } = await client
      .from("message_templates")
      .update({ status: record.status })
      .eq("organization_id", organizationId)
      .eq("id", templateId)
      .eq("status", "pending_deletion");
    if (restoreError) {
      log.error("Could not restore template status after deletion failure", {
        organizationId,
        templateId,
        restoreError,
      });
    }
    throw error;
  }

  const { data, error } = await client
    .from("message_templates")
    .update({
      status: "deleted",
      rejection_reason: null,
      synced_at: new Date().toISOString(),
    })
    .eq("organization_id", organizationId)
    .eq("id", templateId)
    .eq("status", "pending_deletion")
    .select()
    .maybeSingle();

  if (error || !data) {
    throw new HTTPException(500, {
      message: "Template was deleted on Meta but could not be saved locally",
      cause: error,
    });
  }

  return { template: data };
}

export async function createTemplateDraft(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
  createdBy: string | null,
  template: TemplateDraftInput,
) {
  const { data, error } = await client
    .from("message_templates")
    .insert({
      organization_id: organizationId,
      organization_address: organizationAddress,
      created_by: createdBy,
      name: template.name,
      language: template.language,
      category: template.category.toLowerCase(),
      components: template.components as unknown as Json,
      status: "draft",
    })
    .select()
    .single();

  if (error) {
    throw new HTTPException(400, {
      message: "Could not save template draft",
      cause: error,
    });
  }

  return data;
}

export async function updateTemplateDraft(
  client: SupabaseClient<Database>,
  organizationId: string,
  draftId: string,
  organizationAddress: string,
  template: TemplateDraftInput,
) {
  const { data, error } = await client
    .from("message_templates")
    .update({
      organization_address: organizationAddress,
      name: template.name,
      language: template.language,
      category: template.category.toLowerCase(),
      components: template.components as unknown as Json,
    })
    .eq("organization_id", organizationId)
    .eq("id", draftId)
    .eq("status", "draft")
    .select()
    .maybeSingle();

  if (error) {
    throw new HTTPException(400, {
      message: "Could not update template draft",
      cause: error,
    });
  }
  if (!data) {
    throw new HTTPException(404, { message: "Template draft not found" });
  }

  return data;
}

export async function deleteTemplateDraft(
  client: SupabaseClient<Database>,
  organizationId: string,
  draftId: string,
) {
  const { data, error } = await client
    .from("message_templates")
    .delete()
    .eq("organization_id", organizationId)
    .eq("id", draftId)
    .eq("status", "draft")
    .select("id")
    .maybeSingle();

  if (error) {
    throw new HTTPException(400, {
      message: "Could not delete template draft",
      cause: error,
    });
  }
  if (!data) {
    throw new HTTPException(404, { message: "Template draft not found" });
  }

  return { success: true };
}

export async function submitTemplateDraft(
  client: SupabaseClient<Database>,
  organizationId: string,
  draftId: string,
  template: TemplateDraftInput,
) {
  const { data: draft, error: draftError } = await client
    .from("message_templates")
    .select("id, organization_address, status")
    .eq("organization_id", organizationId)
    .eq("id", draftId)
    .eq("status", "draft")
    .maybeSingle();

  if (draftError) {
    throw new HTTPException(400, {
      message: "Could not load template draft",
      cause: draftError,
    });
  }
  if (!draft) {
    throw new HTTPException(404, { message: "Template draft not found" });
  }

  const metaTemplate = await submitTemplateToMeta(
    client,
    organizationId,
    draft.organization_address,
    template,
  );
  const now = new Date().toISOString();
  const status = metaTemplate.status.toLowerCase();

  const { data, error } = await client
    .from("message_templates")
    .update({
      name: template.name,
      language: template.language,
      category: metaTemplate.category.toLowerCase(),
      components: template.components as unknown as Json,
      external_id: metaTemplate.id,
      status,
      rejection_reason: null,
      submitted_at: now,
      synced_at: now,
    })
    .eq("organization_id", organizationId)
    .eq("id", draftId)
    .eq("status", "draft")
    .select()
    .single();

  if (error) {
    throw new HTTPException(500, {
      message: "Template was submitted to Meta but could not be saved locally",
      cause: error,
    });
  }

  return data;
}

export async function syncTemplates(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
) {
  const templates = await listAllTemplates(
    client,
    organizationId,
    organizationAddress,
  );

  if (!templates.length) return { synced: 0 };

  const { data: deletedTemplates, error: deletedTemplatesError } = await client
    .from("message_templates")
    .select("external_id")
    .eq("organization_id", organizationId)
    .eq("organization_address", organizationAddress)
    .eq("status", "deleted");

  if (deletedTemplatesError) {
    throw new HTTPException(500, {
      message: "Could not load deleted templates",
      cause: deletedTemplatesError,
    });
  }

  const deletedExternalIds = new Set(
    deletedTemplates.map((template) => template.external_id).filter(Boolean),
  );

  const syncedAt = new Date().toISOString();
  const rows = templates
    .filter((template) => !deletedExternalIds.has(template.id))
    .map((template) => ({
      organization_id: organizationId,
      organization_address: organizationAddress,
      external_id: template.id,
      name: template.name,
      language: template.language,
      category: template.category.toLowerCase(),
      status: template.status.toLowerCase(),
      components: template.components as unknown as Json,
      rejection_reason: template.rejected_reason || null,
      synced_at: syncedAt,
    }));

  if (!rows.length) return { synced: 0 };
  const { error } = await client
    .from("message_templates")
    .upsert(rows, {
      onConflict: "organization_id,organization_address,name,language",
    });

  if (error) {
    throw new HTTPException(500, {
      message: "Could not synchronize templates",
      cause: error,
    });
  }

  return { synced: rows.length };
}

export async function listTemplateRecordsPage(
  client: SupabaseClient<Database>,
  organizationId: string,
  params: TemplatePageParams,
) {
  const { data, error } = await client.rpc("list_message_templates_page", {
    p_organization_id: organizationId,
    p_page: params.page ?? 1,
    p_page_size: params.pageSize ?? 10,
    p_search: params.search ?? undefined,
    p_organization_address: params.organizationAddress ?? undefined,
    p_category: params.category ?? undefined,
    p_status: params.status ?? undefined,
  });

  if (error) {
    throw new HTTPException(400, {
      message: "Could not list templates",
      cause: error,
    });
  }

  const total = Number(data?.[0]?.total_count ?? 0);
  const rows = (data || []).map(({ total_count: _totalCount, ...row }) => row);

  return { rows, total };
}
