import { createUnsecureClient } from "../_shared/supabase.ts";
import { csvHeader } from "./csv.ts";
import { type ExportJob, processExportPart } from "./worker.ts";

const BUCKET = "campaign-log-exports";
const service = createUnsecureClient();
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Cache-Control": "no-store",
};

// The worker only reads export snapshots and writes private export files. It has
// no imports/calls into dispatch, recipient resolution, Meta or campaign workers.
async function work() {
  const until = Date.now() + 20_000;
  for (let n = 0; n < 20 && Date.now() < until; n++) {
    const worked = await processExportPart({
      async claim() {
        const { data } = await service.rpc("claim_campaign_log_export")
          .throwOnError();
        return data?.id ? data as ExportJob : null;
      },
      async rows(job) {
        const { data } = await service.from("campaign_log_export_rows")
          .select("sent_at,recipient,recipient_name,variables,status")
          .eq("export_id", job.id).gt("ordinal", job.processed_count)
          .order("ordinal").limit(100).throwOnError();
        return data;
      },
      async upload(path, content) {
        const { error } = await service.storage.from(BUCKET).upload(
          path,
          new Blob([content], { type: "text/csv" }),
          {
            upsert: true,
            contentType: "text/csv",
            cacheControl: "0",
          },
        );
        if (error) throw error;
      },
      async finish(job, success) {
        const { data } = await service.rpc("finish_campaign_log_export_part", {
          p_export_id: job.id,
          p_token: job.lease_token,
          p_success: success,
        }).throwOnError();
        return data === true;
      },
    });
    if (!worked) break;
  }
  // Bounded cleanup includes orphaned uploads from a crash before checkpointing.
  const { data: expired } = await service.rpc(
    "campaign_log_export_cleanup_candidates",
  ).throwOnError();
  for (const id of expired) {
    const bucket = service.storage.from(BUCKET);
    const { data: files, error } = await bucket.list(id, { limit: 100 });
    if (error) throw error;
    if (files?.length) {
      const { error: removeError } = await bucket.remove(
        files.map((f) => `${id}/${f.name}`),
      );
      if (removeError) throw removeError;
    } else {
      await service.from("campaign_log_exports").delete().eq("id", id)
        .lte("expires_at", new Date().toISOString()).throwOnError();
    }
  }
}

async function download(req: Request): Promise<Response> {
  const body = await req.text();
  if (
    body.length > 100 ||
    !req.headers.get("content-type")?.startsWith(
      "application/x-www-form-urlencoded",
    )
  ) {
    return new Response("Invalid download request", {
      status: 400,
      headers: cors,
    });
  }
  const ticket = new URLSearchParams(body).get("ticket") ?? "";
  if (!/^[a-f0-9]{64}$/.test(ticket)) {
    return new Response(null, { status: 403, headers: cors });
  }
  const { data } = await service.rpc("consume_campaign_log_download", {
    p_ticket: ticket,
  }).throwOnError();
  const job = data as { id: string; row_count: number } | null;
  if (!job) {
    return new Response("Export unavailable. Request a new download.", {
      status: 403,
      headers: cors,
    });
  }
  const encoder = new TextEncoder();
  let part = -1;
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        if (part === -1) {
          part = 0;
          controller.enqueue(encoder.encode(csvHeader));
          return;
        }
        if (part >= Math.ceil(job.row_count / 100)) {
          controller.close();
          return;
        }
        const { data: record } = await service.from("campaign_log_export_parts")
          .select("path").eq("export_id", job.id).eq("part_no", part).single()
          .throwOnError();
        const { data: file, error } = await service.storage.from(BUCKET)
          .download(record.path);
        if (error || !file) throw error ?? new Error("Missing CSV part");
        controller.enqueue(new Uint8Array(await file.arrayBuffer()));
        part++;
      } catch {
        controller.error(new Error("Download interrupted; please retry"));
      }
    },
  });
  return new Response(stream, {
    headers: {
      ...cors,
      "Content-Type": "text/csv;charset=utf-8",
      "Content-Disposition": `attachment; filename="campaign-${job.id}.csv"`,
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (req.method !== "POST") {
    return new Response(null, { status: 405, headers: cors });
  }
  try {
    if (new URL(req.url).pathname.endsWith("/download")) {
      return await download(req);
    }
    const keys = [
      Deno.env.get("EDGE_FUNCTIONS_TOKEN"),
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
    ].filter(Boolean);
    if (
      !keys.some((key) => req.headers.get("Authorization") === `Bearer ${key}`)
    ) {
      return new Response(null, { status: 401, headers: cors });
    }
    await work();
    return Response.json({ processed: true }, { headers: cors });
  } catch {
    // Do not log body, tickets, snapshot data or Storage credentials.
    return Response.json({ message: "Export processing unavailable" }, {
      status: 500,
      headers: cors,
    });
  }
});
