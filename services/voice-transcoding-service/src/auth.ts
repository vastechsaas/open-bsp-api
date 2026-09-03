import type { Config } from "./config.js";

type UserResponse = { id?: string };
type AgentResponse = Array<{
  id: string;
  ai: boolean;
  extra: { invitation?: { status?: string } } | null;
}>;

export async function authorizeTenant(
  config: Config,
  token: string,
  organizationId: string,
): Promise<void> {
  const headers = {
    apikey: config.supabaseAnonKey,
    Authorization: `Bearer ${token}`,
  };
  const userResponse = await fetch(`${config.supabaseUrl}/auth/v1/user`, {
    headers,
  });
  if (!userResponse.ok) throw new Error("unauthorized");
  const user = (await userResponse.json()) as UserResponse;
  if (!user.id) throw new Error("unauthorized");

  const query = new URLSearchParams({
    organization_id: `eq.${organizationId}`,
    user_id: `eq.${user.id}`,
    ai: "eq.false",
    select: "id,ai,extra",
    limit: "1",
  });
  const memberResponse = await fetch(
    `${config.supabaseUrl}/rest/v1/agents?${query}`,
    { headers },
  );
  if (!memberResponse.ok) throw new Error("unauthorized");
  const agents = (await memberResponse.json()) as AgentResponse;
  const agent = agents[0];
  const status = agent?.extra?.invitation?.status ?? "accepted";
  if (!agent || status !== "accepted") throw new Error("unauthorized");
}
