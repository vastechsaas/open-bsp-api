import { z } from "zod";

export const platformReportPayloadSchema = z.object({
  organization_id: z.uuid(),
  report_type: z.enum(["conversations", "campaigns"]),
  month: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/),
  request_id: z.uuid(),
}).strict();
