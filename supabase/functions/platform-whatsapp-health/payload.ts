import { z } from "zod";

export const platformWhatsAppHealthPayloadSchema = z.object({
  organization_id: z.string().uuid(),
  phone_number_id: z.string().trim().min(1).max(64),
  action: z.enum(["test_connection", "refresh_account", "sync_templates"]),
  request_id: z.string().uuid(),
}).strict();

export type PlatformWhatsAppHealthPayload = z.infer<
  typeof platformWhatsAppHealthPayloadSchema
>;

export const ACTION_AUDIT_TYPES = {
  test_connection: "whatsapp.health_check",
  refresh_account: "whatsapp.profile_refresh",
  sync_templates: "whatsapp.template_sync",
} as const;
