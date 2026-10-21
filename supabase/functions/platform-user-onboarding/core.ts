import { z } from "zod";

const uuid = z.uuid();
export const payloadSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("create"),
    organization_id: uuid,
    request_id: uuid,
    member_id: uuid.optional(),
    expected_updated_at: z.string().optional(),
    name: z.string().trim().min(1).max(120),
    email: z.email().trim().toLowerCase().max(320),
    role: z.enum(["owner", "supervisor", "agent"]),
    mode: z.enum(["direct", "invitation"]),
    password: z.string().max(1024).optional(),
    confirmed: z.boolean().optional(),
  }).strict(),
  z.object({
    action: z.enum(["status", "retry", "resend"]),
    organization_id: uuid,
    operation_id: uuid,
    password: z.string().max(1024).optional(),
    delivery_request_id: uuid.optional(),
  }).strict(),
  z.object({
    action: z.literal("preview"),
    operation_id: uuid,
    context: z.string().min(32).max(300),
  }).strict(),
  z.object({
    action: z.literal("complete"),
    operation_id: uuid,
    context: z.string().min(32).max(300),
    password: z.string().min(1).max(1024),
  }).strict(),
]);
export type Payload = z.infer<typeof payloadSchema>;
export type Operation = {
  id: string;
  organization_id: string;
  member_id: string;
  intended_user_id: string;
  name: string;
  email: string;
  role: string;
  mode: "direct" | "invitation";
  status: string;
  generation: number;
  failure_code: string | null;
  delivery_accepted_at: string | null;
  delivery_request_id: string | null;
  account_exists?: boolean;
  email_confirmed?: boolean;
  has_password?: boolean;
};
export class SafeFailure extends Error {
  constructor(public code: string, public status = 409) {
    super(code);
  }
}
export async function digest(value: string) {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  ]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
// Reconstruct an ambiguous delivery's context without persisting the raw token.
// Domain separation prevents use as an Auth JWT or another application token.
export async function contextToken(
  op: Pick<Operation, "id" | "generation">,
  secret: string,
) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(
        `platform-onboarding-v1:${op.id}:${op.generation}`,
      ),
    ),
  );
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
export function safeOperation(op: Operation) {
  return {
    operation_id: op.id,
    organization_id: op.organization_id,
    member_id: op.member_id,
    mode: op.mode,
    status: op.status,
    failure_code: op.failure_code,
    invitation_sent_at: op.delivery_accepted_at,
  };
}
export interface Dependencies {
  command: (
    command: string,
    payload: Record<string, unknown>,
  ) => Promise<Operation>;
  createAccount: (op: Operation, password?: string) => Promise<void>;
  send: (
    op: Operation,
    redirect: string,
    continuation: boolean,
  ) => Promise<void>;
  setInitialPassword: (op: Operation, password: string) => Promise<void>;
  secret: string;
  callback: string;
}
export async function execute(payload: Payload, deps: Dependencies) {
  const { command } = deps;
  if (payload.action === "preview") {
    return command("preview", {
      operation_id: payload.operation_id,
      context_hash: await digest(payload.context),
    });
  }
  if (
    payload.action === "create" && payload.mode === "direct" &&
    (!payload.confirmed || !payload.password)
  ) {
    throw new SafeFailure("ONBOARDING_DIRECT_CONFIRMATION_REQUIRED", 400);
  }
  if (
    payload.action === "create" && payload.mode !== "direct" &&
    payload.password !== undefined
  ) {
    throw new SafeFailure("ONBOARDING_INVALID_REQUEST", 400);
  }
  const base = payload.action === "create"
    ? await command("begin", {
      ...payload,
      password: undefined,
      confirmed: undefined,
      action: undefined,
    })
    : await command(payload.action === "complete" ? "preview" : "status", {
      operation_id: payload.operation_id,
      ...("organization_id" in payload
        ? { organization_id: payload.organization_id }
        : {}),
      ...("context" in payload
        ? { context_hash: await digest(payload.context) }
        : {}),
    });
  if (
    payload.action === "status" || base.status === "completed" ||
    (payload.action !== "resend" && base.status === "invitation_sent" &&
      base.delivery_accepted_at)
  ) return safeOperation(base);
  const lease_id = crypto.randomUUID();
  const scope = {
    operation_id: "operation_id" in payload ? payload.operation_id : base.id,
    organization_id: "organization_id" in payload
      ? payload.organization_id
      : undefined,
    lease_id,
  };
  let op = await command(
    payload.action === "complete"
      ? "complete_claim"
      : payload.action === "resend"
      ? "resend"
      : "claim",
    {
      ...scope,
      ...("context" in payload
        ? { context_hash: await digest(payload.context) }
        : {}),
      ...("delivery_request_id" in payload
        ? { delivery_request_id: payload.delivery_request_id }
        : {}),
    },
  );
  if (
    op.status === "completed" ||
    (payload.action === "resend" && op.delivery_accepted_at)
  ) return safeOperation(op);
  try {
    const status = await command("status", { ...scope });
    if (payload.action === "complete") {
      // complete_claim binds recipient, context and membership under the shared
      // team lock. Cancellation/role changes cannot race this bounded lease.
      if (!status.has_password) {
        await deps.setInitialPassword(op, payload.password);
      }
      op = await command("complete_finish", {
        ...scope,
        context_hash: await digest(payload.context),
      });
    } else {
      if (!status.account_exists) {
        if (op.mode === "direct" && !payload.password) {
          throw new SafeFailure("PASSWORD_REENTRY_REQUIRED");
        }
        await deps.createAccount(
          op,
          op.mode === "direct" ? payload.password : undefined,
        );
        op = await command("account_created", scope);
      }
      if (op.mode === "direct") op = await command("finish", scope);
      else if (!op.delivery_accepted_at) {
        const token = await contextToken(op, deps.secret);
        op = await command("context", {
          ...scope,
          context_hash: await digest(token),
        });
        const url = new URL(deps.callback);
        url.searchParams.set("operation_id", op.id);
        url.searchParams.set("context", token);
        await deps.send(op, url.toString(), !!status.email_confirmed);
        op = await command("sent", scope);
      }
    }
    return safeOperation(op);
  } catch (error) {
    const code = error instanceof SafeFailure
      ? error.code
      : "FINALIZATION_FAILED";
    const failure = [
        "AUTH_UNAVAILABLE",
        "AUTH_REJECTED",
        "PASSWORD_REENTRY_REQUIRED",
        "WEAK_PASSWORD",
        "SMTP_FAILED",
        "DELIVERY_UNKNOWN",
      ].includes(code)
      ? code
      : "FINALIZATION_FAILED";
    await command("failed", { ...scope, code: failure }).catch(() => {});
    throw new SafeFailure(
      code === "ONBOARDING_EMAIL_IN_USE" ? code : failure,
      error instanceof SafeFailure ? error.status : 503,
    );
  }
}
