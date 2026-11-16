import { createUnsecureClient } from "../_shared/supabase_client.ts";
import { MAX_STORAGE_UPLOAD_SIZE } from "../_shared/media.ts";
import { fetchWhatsAppAttachment } from "./recover.ts";

const internalKeys = [
  Deno.env.get("EDGE_FUNCTIONS_TOKEN"),
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
].filter(Boolean);

Deno.serve(async (request) => {
  if (
    request.method !== "POST" ||
    !internalKeys.some((key) =>
      request.headers.get("Authorization") === `Bearer ${key}`
    )
  ) return new Response(null, { status: 401 });
  if (Deno.env.get("WHATSAPP_ATTACHMENT_RECOVERY_ENABLED") !== "true") {
    return new Response(null, { status: 204 });
  }

  const client = createUnsecureClient((input, init) =>
    fetch(input, { ...init, signal: AbortSignal.timeout(12_000) })
  );
  try {
    const { data: claim } = await client.rpc(
      "claim_whatsapp_attachment_recovery",
    )
      .throwOnError();
    const job = claim?.[0];
    if (!job) return new Response(null, { status: 204 });

    const context = async () => {
      const { data } = await client.rpc(
        "whatsapp_attachment_recovery_context",
        {
          p_message_id: job.message_id,
          p_lease_token: job.lease_token,
        },
      ).throwOnError();
      return data?.[0];
    };
    const finish = async (
      outcome: string,
      path?: string,
      size?: number,
      retryAfter?: number,
    ) => {
      await client.rpc("finish_whatsapp_attachment_recovery", {
        p_message_id: job.message_id,
        p_lease_token: job.lease_token,
        p_outcome: outcome,
        p_path: path,
        p_size: size,
        p_retry_after: retryAfter,
      }).throwOnError();
      return new Response(null, { status: 204 });
    };

    const target = await context();
    if (!target) return await finish("cancelled");
    if (target.account_status !== "connected") {
      return await finish("credentials");
    }
    const token = target.access_token ||
      Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") || "";
    const result = await fetchWhatsAppAttachment({
      mediaId: target.media_id,
      phoneNumberId: target.organization_address,
      token,
      limit: MAX_STORAGE_UPLOAD_SIZE,
    });
    if (result.outcome !== "ready") {
      return await finish(
        result.outcome,
        undefined,
        undefined,
        result.retryAfter,
      );
    }
    const current = await context();
    if (!current) return await finish("cancelled");
    if (current.account_status !== "connected") {
      return await finish("credentials");
    }
    if (current.access_token !== target.access_token) {
      return await finish("temporary");
    }

    // Use the same content-addressed private path as the existing media helper,
    // but never overwrite an object: a crash or another message may own it.
    const path =
      `organizations/${current.organization_id}/attachments/${result.digest}`;
    const { error } = await client.storage.from("media").upload(
      path,
      new Blob([result.bytes], { type: result.mime }),
      {
        contentType: result.mime,
        upsert: false,
        metadata: { name: current.filename },
      },
    );
    if (error) {
      const code = Number("statusCode" in error ? error.statusCode : 0);
      if (code !== 409 && !/already exists|duplicate/i.test(error.message)) {
        return await finish(
          code === 0 || code === 429 || code >= 500 ? "temporary" : "storage",
        );
      }
    }
    return await finish("ready", path, result.bytes.length);
  } catch {
    // The durable lease will recover this job. Do not log Storage or Meta
    // exception text because it can contain a credential or a download URL.
    console.error(
      "WhatsApp attachment recovery worker could not complete a job",
    );
    return new Response(null, { status: 503 });
  }
});
