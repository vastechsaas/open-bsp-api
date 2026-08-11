import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import * as log from "../_shared/logger.ts";
import { createClient } from "../_shared/supabase.ts";
import {
  buildPlatformReportCsv,
  buildReportFilename,
  type PlatformReportType,
} from "./csv.ts";
import { platformReportPayloadSchema } from "./payload.ts";

const PAGE_SIZE = 500;
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Expose-Headers":
    "Content-Disposition, X-Report-Generated-At, X-Report-Row-Count, X-Report-Timezone",
};

type ReportRow = Record<string, unknown> & { total_count?: number };

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (request.method !== "POST") {
    return jsonResponse({ message: "Method not allowed" }, 405);
  }

  try {
    const client = createClient(request);
    const { data: { user }, error: userError } = await client.auth.getUser();

    if (userError || !user) {
      return jsonResponse({ message: "Invalid authentication" }, 401);
    }

    const { data: isPlatformAdmin, error: authorizationError } = await client
      .rpc("is_platform_admin");

    if (authorizationError || !isPlatformAdmin) {
      return jsonResponse(
        { message: "Platform administrator access required" },
        403,
      );
    }

    const payload = platformReportPayloadSchema.parse(await request.json());
    const reportMonth = `${payload.month}-01`;
    const { data: summaries, error: summaryError } = await client.rpc(
      "get_platform_tenant_summary",
      { p_organization_id: payload.organization_id },
    );

    if (summaryError) throw summaryError;
    const summary = summaries?.[0];

    if (!summary) {
      return jsonResponse({ message: "Organization not found" }, 404);
    }

    const rows: ReportRow[] = [];
    let page = 1;
    let expectedTotal: number | null = null;

    do {
      const result = payload.report_type === "conversations"
        ? await client.rpc("list_platform_conversation_report_rows", {
          p_organization_id: payload.organization_id,
          p_month: reportMonth,
          p_page: page,
          p_page_size: PAGE_SIZE,
        })
        : await client.rpc("list_platform_campaign_report_rows", {
          p_organization_id: payload.organization_id,
          p_month: reportMonth,
          p_page: page,
          p_page_size: PAGE_SIZE,
        });

      if (result.error) throw result.error;
      const pageRows = (result.data || []) as ReportRow[];
      if (expectedTotal === null) {
        expectedTotal = Number(pageRows[0]?.total_count || 0);
      }
      rows.push(...pageRows);
      page += 1;

      if (pageRows.length < PAGE_SIZE) break;
    } while (rows.length < (expectedTotal || 0));

    const generatedAt = new Date().toISOString();
    const csv = buildPlatformReportCsv(
      payload.report_type as PlatformReportType,
      rows,
      generatedAt,
    );
    const filename = buildReportFilename(
      summary.organization_name,
      payload.report_type,
      payload.month,
    );
    const { error: auditError } = await client.rpc(
      "record_platform_report_export",
      {
        p_organization_id: payload.organization_id,
        p_report_type: payload.report_type,
        p_month: reportMonth,
        p_request_id: payload.request_id,
        p_row_count: rows.length,
      },
    );

    if (auditError) throw auditError;

    return new Response(`\ufeff${csv}`, {
      status: 200,
      headers: {
        ...CORS_HEADERS,
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": `attachment; filename="${filename}"`,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "X-Report-Generated-At": generatedAt,
        "X-Report-Row-Count": String(rows.length),
        "X-Report-Timezone": "UTC",
      },
    });
  } catch (error) {
    if (error instanceof z.ZodError || error instanceof SyntaxError) {
      return jsonResponse({ message: "Invalid report request" }, 400);
    }

    const databaseError = error as { code?: string; message?: string };
    if (databaseError.code === "42501") {
      return jsonResponse(
        { message: "Platform administrator access required" },
        403,
      );
    }
    if (databaseError.code === "P0002") {
      return jsonResponse({ message: "Organization not found" }, 404);
    }

    log.error("Platform report export failed", error);
    return jsonResponse({ message: "Report generation failed" }, 500);
  }
});
