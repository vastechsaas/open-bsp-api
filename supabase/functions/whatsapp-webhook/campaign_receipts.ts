import type { WebhookStatus } from "../_shared/types/status_types.ts";
import type { MetaWebhookPayload } from "../_shared/types/whatsapp_webhook_payload_types.ts";

export type Receipt = {
  p_organization_id: string;
  p_organization_address: string;
  p_external_id: string;
  p_receipt_type: string;
  p_provider_at: string;
  p_correlation?: string;
  p_error_code?: string;
};

/** Validate the whole batch before writing. Never process accompanying messages/configuration. */
export async function retainReceiptOnlyBatch(
  payload: MetaWebhookPayload,
  organizationId: string | undefined,
  accounts: Map<string, { organization_id: string; address: string }>,
  ingest: (receipt: Receipt) => Promise<boolean>,
): Promise<boolean> {
  const receipts: Array<{ address: string; status: WebhookStatus }> = [];
  for (const entry of payload.entry) {
    for (const { field, value } of entry.changes) {
      if (field !== "messages" || !("statuses" in value)) continue;
      const account = accounts.get(value.metadata.phone_number_id);
      if (
        !organizationId || !account ||
        account.organization_id !== organizationId
      ) return false;
      for (const status of value.statuses) {
        receipts.push({ address: account.address, status });
      }
    }
  }
  for (const { address, status } of receipts) {
    await retainCampaignReceipt(ingest, organizationId!, address, status);
  }
  return true;
}

/** Only call after signature validation and authoritative account resolution. */
export async function retainCampaignReceipt(
  ingest: (receipt: Receipt) => Promise<boolean>,
  organizationId: string,
  address: string,
  status: WebhookStatus,
): Promise<boolean> {
  if (!["sent", "delivered", "read", "failed"].includes(status.status)) {
    return false;
  }
  const seconds = Number(status.timestamp);
  if (!Number.isFinite(seconds) || seconds < 0 || seconds > 253402300799) {
    throw new Error("Invalid receipt timestamp");
  }
  const code = status.errors?.[0]?.code;
  return await ingest({
    p_organization_id: organizationId,
    p_organization_address: address,
    p_external_id: status.id,
    p_receipt_type: status.status,
    p_provider_at: new Date(seconds * 1000).toISOString(),
    ...(status.biz_opaque_callback_data
      ? { p_correlation: status.biz_opaque_callback_data }
      : {}),
    ...(code !== undefined ? { p_error_code: `meta_${code}` } : {}),
  });
}
