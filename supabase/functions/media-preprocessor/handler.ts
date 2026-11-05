import { hasInternalServiceAuth } from "../_shared/internal_auth.ts";
import type { MessageRow, Part } from "../_shared/supabase.ts";

export type MediaResult = {
  outcome: "succeeded" | "skipped";
  artifacts?: Part[];
};
export type MediaRepository = {
  reserve(id: string): Promise<string | null>;
  start(id: string, token: string): Promise<boolean>;
  message(id: string): Promise<MessageRow>;
  finish(
    id: string,
    token: string,
    result: MediaResult | { outcome: "retry" },
  ): Promise<boolean>;
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function createMediaHandler(deps: {
  edgeToken?: string;
  serviceRoleKey?: string;
  repository: MediaRepository;
  process(message: MessageRow): Promise<MediaResult>;
}) {
  return async (request: Request): Promise<Response> => {
    if (!hasInternalServiceAuth(request, deps.edgeToken, deps.serviceRoleKey)) {
      return new Response("Unauthorized", { status: 401 });
    }
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }
    const input = await request.json().catch(() => null);
    // Preserve legacy database-trigger requests; never trust their message contents.
    const id = input?.message_id ?? input?.record?.id;
    const suppliedToken = input?.lease_token;
    if (
      typeof id !== "string" || !uuid.test(id) ||
      (suppliedToken !== undefined &&
        (typeof suppliedToken !== "string" || !uuid.test(suppliedToken)))
    ) {
      return new Response("Invalid preprocessing request", { status: 400 });
    }
    let token: string | null | undefined = suppliedToken;
    let started = false;
    try {
      token ??= await deps.repository.reserve(id);
      if (!token || !await deps.repository.start(id, token)) {
        return Response.json({ skipped: true });
      }
      started = true;
      const current = await deps.repository.message(id);
      const result = await deps.process(current);
      const applied = await deps.repository.finish(id, token, result);
      return Response.json({ applied }, { status: applied ? 200 : 409 });
    } catch {
      if (started && token) {
        await deps.repository.finish(id, token, { outcome: "retry" }).catch(
          () => false,
        );
      }
      // No payload, tokens, provider response or repeated polling logs.
      return new Response("Media preprocessing unavailable", { status: 503 });
    }
  };
}
