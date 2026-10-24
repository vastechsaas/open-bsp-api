import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "./logger.ts";

/**
 * Backport of upstream c6fa999: detect revoked tokens between refresh sweeps.
 * The existing merge_update trigger preserves credentials/profile fields.
 * Never mark a WhatsApp connection or another tenant's connection.
 */
export async function flagNeedsReauth(
  client: SupabaseClient,
  organization_id: string,
  address: string,
  failed_access_token: string,
): Promise<void> {
  log.warn("Instagram connection requires reconnection", {
    organization_id,
    address,
  });
  await client
    .from("organizations_addresses")
    .update({ extra: { needs_reauth: new Date().toISOString() } })
    .eq("organization_id", organization_id)
    .eq("service", "instagram")
    .eq("address", address)
    // A delayed failure from the previous token must not flag a new login.
    .eq("extra->>access_token", failed_access_token)
    .throwOnError();
}
