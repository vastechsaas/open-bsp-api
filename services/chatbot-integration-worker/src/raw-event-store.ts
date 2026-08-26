import { createHash } from "node:crypto";

export type StoreRawEvent = (rawPayload: string) => Promise<void>;

export function createRawEventStore({
  supabaseUrl,
  serviceRoleKey,
  queueName,
  fetchImpl = fetch,
}: {
  supabaseUrl: string;
  serviceRoleKey: string;
  queueName: string;
  fetchImpl?: typeof fetch;
}): StoreRawEvent {
  const endpoint = new URL(
    "/rest/v1/chatbot_integration_raw_events?on_conflict=payload_sha256",
    `${supabaseUrl.replace(/\/$/, "")}/`,
  );

  return async (rawPayload: string) => {
    const payloadSha256 = createHash("sha256").update(rawPayload, "utf8")
      .digest("hex");
    const response = await fetchImpl(endpoint, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
        prefer: "resolution=ignore-duplicates,return=minimal",
      },
      body: JSON.stringify({
        payload_sha256: payloadSha256,
        queue_name: queueName,
        raw_payload: rawPayload,
      }),
    });

    if (!response.ok) {
      throw new Error(`Supabase raw-event insert failed with ${response.status}`);
    }
  };
}
