import { createDispatchHandler, type DispatchRepository } from "./handler.ts";
import { createUnsecureClient } from "../_shared/supabase.ts";
import { buildCampaignTemplatePayload } from "../_shared/campaign_template.ts";
import { prepareCampaignCarouselMedia } from "../whatsapp-management/campaign_media.ts";
import {
  getWhatsAppErrorDetails,
  postPayloadToWhatsAppEndpoint,
  resolveWhatsAppRecipient,
  WhatsAppError,
} from "../_shared/whatsapp.ts";

const client = createUnsecureClient();
const repository: DispatchRepository = {
  async status(id) {
    const { data } = await client.from("campaign_dispatch_jobs")
      .select(
        "id,organization_id,campaign_id,delivery_id,phase,error_code,external_id",
      ).eq("id", id).maybeSingle().throwOnError();
    return data;
  },
  async claim(id) {
    const { data } = await client.rpc("claim_campaign_dispatch_job", {
      p_job_id: id,
    }).throwOnError();
    return data as { phase: string; lease_token?: string } | null;
  },
  async begin(id, token) {
    const { data } = await client.rpc("begin_campaign_dispatch_send", {
      p_job_id: id,
      p_token: token,
    }).throwOnError();
    return data === true;
  },
  async finish(id, token, outcome, externalId, code) {
    const { data } = await client.rpc("finish_campaign_dispatch_job", {
      p_job_id: id,
      p_token: token,
      p_outcome: outcome,
      ...(externalId ? { p_external_id: externalId } : {}),
      ...(code ? { p_error_code: code } : {}),
    }).throwOnError();
    return data!;
  },
};

Deno.serve(createDispatchHandler({
  repository,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
  async prepare(job) {
    const { data: campaign } = await client.from("campaigns").select("*")
      .eq("organization_id", job.organization_id).eq("id", job.campaign_id)
      .single().throwOnError();
    const { data: delivery } = await client.from("campaign_deliveries").select(
      "*",
    )
      .eq("organization_id", job.organization_id).eq(
        "campaign_id",
        job.campaign_id,
      ).eq("id", job.delivery_id).single().throwOnError();
    const { data: account } = await client.from("organizations_addresses")
      .select("extra")
      .eq("organization_id", job.organization_id).eq(
        "address",
        campaign.organization_address,
      )
      .eq("service", "whatsapp").eq("status", "connected").single()
      .throwOnError();
    const extra = account.extra as { access_token?: string };
    const accessToken = extra.access_token ||
      Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") || "";
    if (!accessToken) throw new Error("account_unavailable");
    const carouselMedia = await prepareCampaignCarouselMedia(
      client,
      job.organization_id,
      campaign.organization_address,
      campaign.template,
      campaign.carousel_media,
    );
    const recipient = await resolveWhatsAppRecipient({
      client,
      organizationId: job.organization_id,
      contactAddress: delivery.contact_address,
    });
    const payload = buildCampaignTemplatePayload({
      template: campaign.template,
      mapping: campaign.template_variable_mapping,
      headerMedia: campaign.header_media,
      carouselMedia,
      delivery: {
        contactAddress: delivery.contact_address,
        contactName: delivery.name,
        variables: delivery.variables,
      },
      ...recipient,
    });
    return {
      payload,
      phoneNumberId: campaign.organization_address,
      accessToken,
    };
  },
  send: (prepared) => postPayloadToWhatsAppEndpoint(prepared),
  classify(error) {
    const detail = getWhatsAppErrorDetails(error);
    return {
      retryable: detail.isRetryable,
      // A generic gateway/5xx body is not evidence that Meta rejected the send.
      definitive: error instanceof WhatsAppError &&
        detail.metaCode !== undefined,
      code: detail.metaCode
        ? `meta_${detail.metaCode}`
        : error instanceof TypeError
        ? "network_error"
        : "dispatch_error",
    };
  },
}));
