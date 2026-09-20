import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import * as log from "../_shared/logger.ts";
import { createClient, createUnsecureClient } from "../_shared/supabase.ts";
import { organizationProvisioningPayloadSchema } from "./payload.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return Response.json(body, {
    status,
    headers: { ...CORS_HEADERS, "Cache-Control": "no-store" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method !== "POST") {
    return json({ message: "Method not allowed" }, 405);
  }

  let client: ReturnType<typeof createClient>;
  try {
    client = createClient(request);
  } catch {
    return json({ message: "Invalid authentication" }, 401);
  }
  let provisioningId: string | undefined;

  try {
    const { data: { user }, error: userError } = await client.auth.getUser();
    if (userError || !user) {
      return json({ message: "Invalid authentication" }, 401);
    }

    const { data: isPlatformAdmin, error: accessError } = await client.rpc(
      "is_platform_admin",
    );
    if (accessError || !isPlatformAdmin) {
      return json({ message: "Platform administrator access required" }, 403);
    }

    const payload = organizationProvisioningPayloadSchema.parse(
      await request.json(),
    );
    const { data: provisioning, error: provisioningError } = await client.rpc(
      "provision_platform_organization",
      {
        p_request_id: payload.request_id,
        p_organization_name: payload.organization_name,
        p_owner_name: payload.owner.name,
        p_owner_email: payload.owner.email,
        p_members: payload.members,
        ...(payload.max_agent_seats === null
          ? {}
          : { p_max_agent_seats: payload.max_agent_seats }),
        p_storage_quota_gb: payload.storage_quota_gb,
        p_auto_assign: payload.auto_assign,
      },
    );
    if (provisioningError) throw provisioningError;
    provisioningId = provisioning.id;

    if (provisioning.status === "completed") {
      return json(provisioning);
    }

    const service = createUnsecureClient();
    const { data: invitations, error: invitationReadError } = await service
      .from("agents")
      .select("id,user_id,name,extra")
      .in("id", provisioning.invitation_agent_ids);
    if (invitationReadError) throw invitationReadError;

    const redirectTo = Deno.env.get("ORGANIZATION_INVITE_REDIRECT_URL");
    for (const invitation of invitations || []) {
      if (invitation.user_id) continue;
      const extra = invitation.extra as {
        invitation?: { email?: string };
      } | null;
      const email = extra?.invitation?.email;
      if (!email) throw new Error("Provisioning invitation email is missing");

      const { error: inviteError } = await service.auth.admin.inviteUserByEmail(
        email,
        {
          data: { full_name: invitation.name },
          ...(redirectTo ? { redirectTo } : {}),
        },
      );
      if (inviteError) throw inviteError;
    }

    const { data: completed, error: completionError } = await client.rpc(
      "finish_platform_organization_provisioning",
      {
        p_provisioning_id: provisioning.id,
        p_status: "completed",
      },
    );
    if (completionError) throw completionError;

    return json(completed, 201);
  } catch (error) {
    if (provisioningId) {
      await client.rpc("finish_platform_organization_provisioning", {
        p_provisioning_id: provisioningId,
        p_status: "failed",
        p_error: error instanceof Error ? error.message : "Invitation failed",
      });
    }

    if (error instanceof z.ZodError || error instanceof SyntaxError) {
      return json({ message: "Invalid organization onboarding request" }, 400);
    }
    const databaseError = error as { code?: string; message?: string };
    if (databaseError.code === "42501") {
      return json({ message: databaseError.message }, 403);
    }
    if (databaseError.code === "23505" || databaseError.code === "23514") {
      return json({ message: databaseError.message }, 409);
    }
    if (databaseError.code === "22023") {
      return json({ message: databaseError.message }, 400);
    }

    log.error("Organization provisioning failed", error);
    return json({ message: "Organization provisioning failed" }, 500);
  }
});
