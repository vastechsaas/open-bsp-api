import { z } from "zod";
import { createUnsecureClient } from "../supabase.ts";

export const episodeSchema = z.object({
  node_conversation_id: z.string().regex(/^\d+$/),
  episode_number: z.number().int().positive(),
  previous_node_conversation_id: z.string().regex(/^\d+$/).optional(),
}).strict();

export function conversationEpisodesEnabled(organizationId: string) {
  return Deno.env.get("NODE_CONVERSATION_EPISODES_ENABLED") === "true" &&
    (Deno.env.get("NODE_CONVERSATION_EPISODE_ORGANIZATIONS") ?? "").split(",")
      .includes(organizationId);
}

export async function resolveConversationEpisode(
  organizationId: string,
  address: string,
  recipient: string,
  episode: z.infer<typeof episodeSchema>,
) {
  // Once enrolled, existing mappings must remain routable during rollback.
  const client = createUnsecureClient();
  if (!conversationEpisodesEnabled(organizationId)) {
    const { data } = await client.from("chatbot_node_conversations").select(
      "episode_number",
    )
      .eq("organization_id", organizationId).eq("organization_address", address)
      .eq("node_conversation_id", episode.node_conversation_id).maybeSingle();
    if (data?.episode_number == null) {
      throw new Error("Conversation episodes are disabled");
    }
  }
  const { data, error } = await client.rpc(
    "resolve_node_conversation_episode",
    {
      p_organization_id: organizationId,
      p_address: address,
      p_recipient: recipient,
      p_node_conversation_id: episode.node_conversation_id,
      p_episode_number: episode.episode_number,
      p_previous_node_conversation_id: episode.previous_node_conversation_id,
    },
  );
  if (error) {
    throw Object.assign(new Error("Conversation episode is not ready"), {
      code: error.code,
    });
  }
  return data;
}
