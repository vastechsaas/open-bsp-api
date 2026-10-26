import { z } from "zod";
import type {
  createClient,
  createUnsecureClient,
} from "../_shared/supabase.ts";
import {
  type Dependencies,
  execute,
  SafeFailure,
} from "../platform-user-onboarding/core.ts";
import {
  accountSetupDependencies,
  assertAccountSetupConfigured,
} from "../platform-user-onboarding/runtime.ts";
const person = z.object({
  name: z.string().trim().min(1).max(120),
  email: z.email().trim().toLowerCase().max(320),
  mode: z.enum(["invitation", "direct", "pending"]).default("invitation"),
}).strict();
export const setupPayloadSchema = z.discriminatedUnion("action", [
  z.object({
    version: z.literal(2),
    action: z.literal("create"),
    request_id: z.uuid(),
    organization_name: z.string().trim().min(1).max(250),
    owner: person,
    members: z.array(
      person.extend({
        client_key: z.string().min(1).max(64),
        role: z.enum(["owner", "supervisor", "agent"]),
      }),
    ).max(50).default([]),
    max_agent_seats: z.number().int().positive().nullable().default(null),
    storage_quota_gb: z.union([
      z.literal(25),
      z.literal(50),
      z.literal(75),
      z.literal(100),
    ]).default(25),
    auto_assign: z.boolean().default(false),
  }).strict(),
  z.object({
    version: z.literal(2),
    action: z.literal("status"),
    provisioning_id: z.uuid(),
  }).strict(),
  z.object({
    version: z.literal(2),
    action: z.literal("continue"),
    provisioning_id: z.uuid(),
    member_id: z.uuid(),
    password: z.string().min(1).max(1024).optional(),
    confirmed: z.boolean().optional(),
  }).strict(),
]);
export type SetupPerson = {
  member_id: string;
  client_key: string;
  name: string;
  email: string;
  role: "owner" | "supervisor" | "agent";
  mode: "invitation" | "direct" | "pending";
  request_id: string;
  expected_updated_at: string;
  operation_id: string | null;
  status: string;
  failure_code: string | null;
  invitation_sent_at: string | null;
};
export type SetupResult = {
  version: 2;
  provisioning_id: string;
  organization_id: string;
  organization_name: string;
  status: string;
  people: SetupPerson[];
  has_remaining_work: boolean;
};
export async function processPerson(
  person: SetupPerson,
  organizationId: string,
  input: { password?: string; confirmed?: boolean },
  deps: Dependencies,
) {
  if (
    ["completed", "invitation_sent", "pending_membership"].includes(
      person.status,
    ) || person.mode === "pending"
  ) return;
  if (person.operation_id) {
    return await execute({
      action: "retry",
      organization_id: organizationId,
      operation_id: person.operation_id,
      ...(input.password ? { password: input.password } : {}),
    }, deps);
  }
  return await execute({
    action: "create",
    organization_id: organizationId,
    request_id: person.request_id,
    member_id: person.member_id,
    expected_updated_at: person.expected_updated_at,
    name: person.name,
    email: person.email,
    role: person.role,
    mode: person.mode,
    ...(input.password
      ? { password: input.password, confirmed: input.confirmed }
      : {}),
  }, deps);
}
export async function handleOrganizationSetup(
  raw: unknown,
  client: ReturnType<typeof createClient>,
  service: ReturnType<typeof createUnsecureClient>,
  actor: string,
) {
  const payload = setupPayloadSchema.parse(raw);
  if (payload.action === "create") {
    const { version: _version, action: _action, request_id, ...safe } = payload;
    const { data, error } = await client.rpc(
      "begin_platform_organization_setup",
      { p_request_id: request_id, p_payload: safe },
    );
    if (error) throw error;
    return data;
  }
  const { data, error } = await client.rpc("get_platform_organization_setup", {
    p_provisioning_id: payload.provisioning_id,
  });
  if (error) throw error;
  if (payload.action === "status") return data;
  const status = data as unknown as SetupResult;
  if (status.version !== 2) {
    throw new SafeFailure("ONBOARDING_VERSION_REQUIRED", 400);
  }
  const person = status.people.find((person) =>
    person.member_id === payload.member_id
  );
  if (!person) throw new SafeFailure("ONBOARDING_NOT_FOUND", 404);
  const { data: active, error: activeError } = await service.rpc(
    "is_organization_active",
    { p_organization_id: status.organization_id },
  );
  if (activeError || !active) {
    throw new SafeFailure("ONBOARDING_FORBIDDEN", 403);
  }
  if (person.mode !== "direct" && payload.password !== undefined) {
    throw new SafeFailure("ONBOARDING_INVALID_REQUEST", 400);
  }
  let failure: string | null = null;
  try {
    if (
      !["completed", "invitation_sent", "pending_membership"].includes(
        person.status,
      )
    ) {
      assertAccountSetupConfigured("create");
      if (
        person.mode === "direct" && !person.operation_id && !payload.password
      ) throw new SafeFailure("PASSWORD_REENTRY_REQUIRED");
      if (person.mode === "direct" && payload.password && !payload.confirmed) {
        throw new SafeFailure("ONBOARDING_DIRECT_CONFIRMATION_REQUIRED", 400);
      }
      await processPerson(
        person,
        status.organization_id,
        payload,
        accountSetupDependencies(service, actor),
      );
    }
  } catch (error) {
    const allowed = new Set([
      "ONBOARDING_EMAIL_IN_USE",
      "ONBOARDING_EMAIL_RESERVED",
      "ONBOARDING_CAPACITY_REACHED",
      "ONBOARDING_BUSY",
      "ONBOARDING_REVOKED",
      "TEAM_MEMBER_STALE",
      "AUTH_UNAVAILABLE",
      "AUTH_REJECTED",
      "PASSWORD_REENTRY_REQUIRED",
      "WEAK_PASSWORD",
      "SMTP_FAILED",
      "DELIVERY_UNKNOWN",
      "FINALIZATION_FAILED",
      "ONBOARDING_NOT_CONFIGURED",
    ]);
    failure = error instanceof SafeFailure && allowed.has(error.code)
      ? error.code
      : "ONBOARDING_INVALID_REQUEST";
  }
  const result = await client.rpc(
    "record_platform_provisioning_person_result",
    {
      p_provisioning_id: payload.provisioning_id,
      p_member_id: payload.member_id,
      p_failure_code: failure ?? undefined,
    },
  );
  if (result.error) throw result.error;
  return result.data;
}
