import * as log from "../_shared/logger.ts";
import { buildCampaignTemplatePayload } from "../_shared/campaign_template.ts";
import { createUnsecureClient } from "../_shared/supabase.ts";
import {
  getWhatsAppErrorDetails,
  postPayloadToWhatsAppEndpoint,
  resolveWhatsAppRecipient,
} from "../_shared/whatsapp.ts";

const BATCH_SIZE = 25;
const DEFAULT_ACCESS_TOKEN = Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") ||
  "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");

  if (!SERVICE_ROLE_KEY || token !== SERVICE_ROLE_KEY) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const client = createUnsecureClient();
  const { data: deliveries } = await client
    .rpc("claim_campaign_deliveries", { p_limit: BATCH_SIZE })
    .throwOnError();

  if (!deliveries?.length) {
    return jsonResponse({ accepted: 0, claimed: 0, failed: 0, queued: 0 });
  }

  const firstDelivery = deliveries[0];
  const { data: account } = await client
    .from("organizations_addresses")
    .select("access_token:extra->>access_token")
    .eq("organization_id", firstDelivery.organization_id)
    .eq("address", firstDelivery.organization_address)
    .single()
    .throwOnError();
  const accessToken = account.access_token || DEFAULT_ACCESS_TOKEN;

  const results = {
    accepted: 0,
    claimed: deliveries.length,
    failed: 0,
    queued: 0,
  };

  for (const delivery of deliveries) {
    try {
      const recipient = await resolveWhatsAppRecipient({
        client,
        organizationId: delivery.organization_id,
        contactAddress: delivery.contact_address,
      });
      const payload = buildCampaignTemplatePayload({
        template: delivery.template,
        mapping: delivery.template_variable_mapping,
        delivery: {
          contactAddress: delivery.contact_address,
          contactName: delivery.contact_name,
          variables: delivery.variables,
        },
        ...recipient,
      });
      const response = await postPayloadToWhatsAppEndpoint({
        payload,
        phoneNumberId: delivery.organization_address,
        accessToken,
      });
      const externalId = response.messages[0]?.id;

      if (!externalId) {
        throw new Error("WhatsApp did not return a message ID");
      }

      await client.rpc("record_campaign_delivery_result", {
        p_delivery_id: delivery.delivery_id,
        p_external_id: externalId,
      }).throwOnError();
      results.accepted += 1;
    } catch (error) {
      const details = getWhatsAppErrorDetails(error);
      const { data: finalStatus } = await client.rpc(
        "record_campaign_delivery_result",
        {
          p_delivery_id: delivery.delivery_id,
          p_error: details.errorDetail,
          p_retryable: details.isRetryable,
        },
      ).throwOnError();

      results[finalStatus === "queued" ? "queued" : "failed"] += 1;
      log.warn("Campaign recipient dispatch failed", {
        campaign_id: delivery.campaign_id,
        delivery_id: delivery.delivery_id,
        attempt: delivery.attempts,
        code: details.metaCode,
        retryable: finalStatus === "queued",
        error: details.errorMessage,
      });
    }
  }

  log.info("Campaign batch processed", {
    campaign_id: firstDelivery.campaign_id,
    ...results,
  });

  return jsonResponse(results);
});
