import { z } from "zod";

export const organizationRoleSchema = z.enum([
  "owner",
  "admin",
  "supervisor",
  "member",
  "agent",
]);

export const organizationProvisioningPayloadSchema = z.object({
  request_id: z.string().uuid(),
  organization_name: z.string().trim().min(1).max(250),
  owner: z.object({
    name: z.string().trim().min(1).max(120),
    email: z.string().trim().email().max(320),
  }),
  members: z.array(z.object({
    name: z.string().trim().min(1).max(120),
    email: z.string().trim().email().max(320),
    role: organizationRoleSchema,
  })).max(50).default([]),
  max_agent_seats: z.number().int().positive().nullable().default(null),
  storage_quota_gb: z.union([
    z.literal(25),
    z.literal(50),
    z.literal(75),
    z.literal(100),
  ]).default(25),
  auto_assign: z.boolean().default(false),
});

export type OrganizationProvisioningPayload = z.infer<
  typeof organizationProvisioningPayloadSchema
>;
