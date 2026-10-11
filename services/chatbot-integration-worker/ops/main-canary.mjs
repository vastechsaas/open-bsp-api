// Explicit operator-run synthetic canary. Never sends a request to Meta.
// Input/config files must be mounted in a private 0700 directory, never committed.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
const require = createRequire("/app/package.json");
const amqp = require("amqplib");
const directory = process.env.CANARY_DIRECTORY || "/canary";
const input = JSON.parse(readFileSync(`${directory}/input.json`, "utf8"));
const env = input.worker;
if (new URL(env.SUPABASE_URL).hostname !== "buvjopvpkgvzhykwsxnk.supabase.co") {
  throw new Error("Main project required");
}
const mode = process.argv[2];
const save = (name, value) =>
  writeFileSync(
    `${directory}/${name}`,
    typeof value === "string" ? value : JSON.stringify(value, null, 2),
    { mode: 0o600 },
  );
const api = async (path, method = "GET", body) => {
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
    method,
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      prefer: "return=representation",
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`Canary API ${path.split("?")[0]} ${response.status}`);
  }
  return response.status === 204 ? [] : response.json();
};
if (mode === "bootstrap") {
  const previous = existsSync(`${directory}/context.json`)
    ? JSON.parse(readFileSync(`${directory}/context.json`, "utf8"))
    : undefined;
  const id = previous?.id ?? randomUUID();
  const suffix = previous?.suffix ?? Date.now().toString();
  const number = `9999${suffix}`;
  const key = previous?.key ?? randomBytes(32).toString("hex");
  const source = Object.values(JSON.parse(env.OPENBSP_ACCOUNT_CONFIG_JSON))[0];
  const integration = `latency-${suffix}`;
  const queue = `openbsp.canary.latency.${suffix}`;
  const customers = previous?.customers ?? Array.from(
    { length: 20 },
    (_, index) => ({
      customer: `999${suffix}${String(index).padStart(2, "0")}`,
      conversation: randomUUID(),
      node: String(900000 + index),
    }),
  );
  const context = {
    id,
    suffix,
    number,
    integration,
    queue,
    customers,
    metaAppId: source.meta_app_id,
    key,
  };
  save("context.json", context);
  if (!previous) {
    await api("organizations", "POST", {
      id,
      name: `TEST Worker latency ${suffix}`,
      extra: { authorized_contacts_only: true, response_delay_seconds: 0 },
    });
    await api("organizations_addresses", "POST", {
      organization_id: id,
      service: "whatsapp",
      address: number,
      status: "connected",
      extra: {
        waba_id: `9998${suffix}`,
        phone_number: number,
        verified_name: "Synthetic worker canary",
      },
    });
    await api("api_keys", "POST", {
      organization_id: id,
      role: "owner",
      name: integration,
      key,
    });
    await api("chatbot_node_bridges", "POST", {
      organization_id: id,
      organization_address: number,
      engine: "disabled",
      node_company_id: "999999",
      sync_status: "disabled",
    });
  }
  await api(
    "contacts_addresses",
    "POST",
    customers.map(({ customer }) => ({
      organization_id: id,
      address: customer,
      service: "whatsapp",
      extra: { profile: { name: "Synthetic canary" } },
    })),
  );
  await api(
    "conversations",
    "POST",
    customers.map(({ customer, conversation }) => ({
      id: conversation,
      organization_id: id,
      organization_address: number,
      contact_address: customer,
      service: "whatsapp",
      name: "Synthetic worker canary",
      status: "active",
    })),
  );
  await api(
    "chatbot_node_conversations",
    "POST",
    customers.map(({ node, conversation }) => ({
      organization_id: id,
      organization_address: number,
      node_conversation_id: node,
      conversation_id: conversation,
      episode_number: 1,
      human_owned: false,
      lifecycle_enabled: true,
      state: "bot_ready",
    })),
  );
  const canary = {
    ...env,
    OPENBSP_ACCOUNT_CONFIG_JSON: JSON.stringify({
      [integration]: {
        ...source,
        phone_number_id: number,
        chatbot: { key: integration, name: "Synthetic latency canary" },
        openbsp_api_key: key,
      },
    }),
    RABBITMQ_QUEUE: queue,
    RABBITMQ_ROUTING_KEY: queue,
    RABBITMQ_DLQ: `${queue}.dlq`,
    RABBITMQ_DLQ_ROUTING_KEY: `${queue}.dlq`,
    OPENBSP_EDGE_REGION: "ap-northeast-1",
    WORKER_MODE: process.env.CANARY_WORKER_MODE || "parallel",
    WORKER_MESSAGE_CONCURRENCY: process.env.CANARY_MESSAGE_CONCURRENCY || "4",
    WORKER_STATUS_CONCURRENCY: process.env.CANARY_STATUS_CONCURRENCY || "2",
  };
  save(
    "worker.env",
    Object.entries(canary).map(([name, value]) => `${name}=${value}`).join(
      "\n",
    ) + "\n",
  );
  console.log(
    JSON.stringify({ organization: id, queue, synthetic_customers: 20 }),
  );
} else {
  const ctx = JSON.parse(readFileSync(`${directory}/context.json`, "utf8"));
  if (!ctx.queue.startsWith("openbsp.canary.latency.")) {
    throw new Error("Isolated canary queue required");
  }
  if (mode === "run") {
    const connection = await amqp.connect(env.CLOUDAMQP_URL);
    const channel = await connection.createConfirmChannel();
    let unroutable = false;
    channel.on("return", () => {
      unroutable = true;
    });
    const samples = [];
    const webhook = (value, episodeWamid, episode) => {
      const raw = JSON.stringify({
        object: "whatsapp_business_account",
        entry: [{
          id: `9998${ctx.suffix}`,
          changes: [{
            field: "messages",
            value: {
              messaging_product: "whatsapp",
              metadata: {
                phone_number_id: ctx.number,
                display_phone_number: ctx.number,
              },
              ...value,
            },
          }],
        }],
      });
      return {
        raw_body: raw,
        x_hub_signature_256: `sha256=${
          createHmac("sha256", input.metaSecret).update(raw).digest("hex")
        }`,
        app_id: ctx.metaAppId,
        node_messages: { [episodeWamid]: episode },
      };
    };
    const publish = (type, payload, occurred) => {
      const event = {
        version: 1,
        event_id: randomUUID(),
        event_type: type,
        integration_key: ctx.integration,
        occurred_at: occurred,
        payload,
      };
      channel.publish(
        env.RABBITMQ_EXCHANGE || "openbsp.integration",
        ctx.queue,
        Buffer.from(JSON.stringify(event)),
        { persistent: true, mandatory: true, messageId: event.event_id },
      );
      return event;
    };
    try {
      for (let index = 0; index < ctx.customers.length; index++) {
        const { customer, node, conversation } = ctx.customers[index];
        const episode = { node_conversation_id: node, episode_number: 1 };
        const occurred = new Date().toISOString();
        const timestamp = String(Math.floor(Date.now() / 1000));
        const incoming = `wamid.canary.${ctx.suffix}.${index}.in`;
        const outgoing = `wamid.canary.${ctx.suffix}.${index}.out`;
        publish(
          "whatsapp_webhook",
          webhook(
            {
              contacts: [{
                profile: { name: "Synthetic canary" },
                wa_id: customer,
              }],
              messages: [{
                id: incoming,
                from: customer,
                timestamp,
                type: "text",
                text: { body: "Synthetic canary input" },
              }],
            },
            incoming,
            episode,
          ),
          occurred,
        );
        const reply = publish("chatbot_reply", {
          episode,
          phone_number_id: ctx.number,
          recipient: customer,
          wamid: outgoing,
          reply_to_wamid: incoming,
          sent_at: occurred,
          message: { type: "text", text: { body: "Synthetic canary reply" } },
        }, occurred);
        for (
          const status of ["sent", "delivered", "read", "delivered", "read"]
        ) {
          publish(
            "whatsapp_webhook",
            webhook(
              {
                statuses: [{
                  id: outgoing,
                  recipient_id: customer,
                  status,
                  timestamp,
                }],
              },
              outgoing,
              episode,
            ),
            occurred,
          );
        }
        if (index === 0) {
          channel.publish(
            env.RABBITMQ_EXCHANGE || "openbsp.integration",
            ctx.queue,
            Buffer.from(JSON.stringify(reply)),
            { persistent: true, mandatory: true, messageId: reply.event_id },
          );
        }
        samples.push({ incoming, outgoing, occurred, conversation });
        await channel.waitForConfirms();
        if (unroutable) {
          throw new Error("Canary queue not ready/bound; publication returned");
        }
        await new Promise((resolve) => setTimeout(resolve, 2_000));
      }
      save("samples.json", samples);
      console.log(
        JSON.stringify({
          published: 141,
          customer_reply_pairs: 20,
          status_events: 100,
          duplicate_reply_events: 1,
          pair_interval_ms: 2000,
        }),
      );
    } finally {
      await connection.close();
    }
  } else if (mode === "replay") {
    // Repeat only already persisted synthetic envelopes to test shutdown and
    // redelivery. No new event IDs, messages, or customer actions are created.
    const rows = await api(
      `chatbot_integration_raw_events?queue_name=eq.${ctx.queue}&select=raw_payload&limit=40`,
    );
    if (rows.length !== 40) {
      throw new Error("Completed canary required for replay");
    }
    const connection = await amqp.connect(env.CLOUDAMQP_URL);
    try {
      const channel = await connection.createConfirmChannel();
      let returned = false;
      channel.on("return", () => {
        returned = true;
      });
      const started = new Date().toISOString();
      const ids = rows.map((row) => {
        const event = JSON.parse(row.raw_payload);
        channel.publish(
          env.RABBITMQ_EXCHANGE || "openbsp.integration",
          ctx.queue,
          Buffer.from(row.raw_payload),
          { persistent: true, mandatory: true, messageId: event.event_id },
        );
        return event.event_id;
      });
      await channel.waitForConfirms();
      if (returned) throw new Error("Replay publication returned");
      save("replay.json", { started, ids });
      console.log(JSON.stringify({ replayed_existing_events: ids.length }));
    } finally {
      await connection.close();
    }
  } else if (mode === "verify") {
    const samples = JSON.parse(
      readFileSync(`${directory}/samples.json`, "utf8"),
    );
    const rows = await api(
      `messages?organization_id=eq.${ctx.id}&select=id,external_id,conversation_id,content,status,created_at`,
    );
    const mappings = await api(
      `chatbot_node_conversations?organization_id=eq.${ctx.id}&select=state,ownership_revision,human_owned`,
    );
    const timings = samples.flatMap((sample) =>
      [sample.incoming, sample.outgoing].map((id) => {
        const matches = rows.filter((row) => row.external_id === id);
        if (
          matches.length !== 1 ||
          matches[0].conversation_id !== sample.conversation ||
          !Object.keys(matches[0].content).length
        ) throw new Error("Missing/duplicate/misrouted canary message");
        if (
          id === sample.outgoing &&
          (!matches[0].status.read || !matches[0].status.delivered)
        ) throw new Error("Status not merged");
        return Date.parse(matches[0].created_at) - Date.parse(sample.occurred);
      })
    ).sort((a, b) => a - b);
    if (
      rows.length !== 40 ||
      mappings.some((row) =>
        row.human_owned || row.state !== "bot_ready" ||
        row.ownership_revision !== "0"
      )
    ) throw new Error("Canary ownership/count mismatch");
    // Database insertion precedes response completion. The rollout gate must
    // include storage, handler completion and durable retries, not insertion
    // alone. Capture `docker logs <canary> > worker.log` in this private mount.
    const rawEvents = await api(
      `chatbot_integration_raw_events?queue_name=eq.${ctx.queue}&select=raw_payload`,
    );
    const events = rawEvents.map((row) => JSON.parse(row.raw_payload));
    const logs = readFileSync(`${directory}/worker.log`, "utf8").split("\n")
      .flatMap((line) => {
        try {
          return [JSON.parse(line)];
        } catch {
          return [];
        }
      });
    const completions = events.map((event) => {
      const success = logs.find((line) =>
        [
          "Edge Function request completed",
          "Confirmed duplicate status acknowledged",
        ].includes(line.message) &&
        line.event_id === event.event_id && line.response_status >= 200 &&
        line.response_status < 300
      );
      if (!success) throw new Error("Canary event has no confirmed forwarding");
      return {
        type: event.event_type,
        duration: Date.parse(success.timestamp) - Date.parse(event.occurred_at),
      };
    });
    if (completions.length !== 140) {
      throw new Error("Canary raw-event count mismatch");
    }
    if (existsSync(`${directory}/replay.json`)) {
      const replay = JSON.parse(
        readFileSync(`${directory}/replay.json`, "utf8"),
      );
      for (const id of replay.ids) {
        if (
          !logs.some((line) =>
            line.event_id === id &&
            [
              "Edge Function request completed",
              "Confirmed duplicate status acknowledged",
            ].includes(line.message) &&
            line.timestamp >= replay.started && line.response_status >= 200 &&
            line.response_status < 300
          )
        ) {
          throw new Error("Replayed event missing after worker restart");
        }
      }
    }
    const percentile = (values) => {
      values.sort((a, b) => a - b);
      return values[Math.ceil(values.length * 0.95) - 1];
    };
    const forwardingP95 = percentile(completions.map((row) => row.duration));
    const report = {
      organization: ctx.id,
      stored_messages: rows.length,
      customer_reply_pairs: 20,
      p95_store_ms: timings[Math.ceil(timings.length * 0.95) - 1],
      max_store_ms: timings.at(-1),
      mean_store_ms: Math.round(
        timings.reduce((sum, value) => sum + value, 0) / timings.length,
      ),
      confirmed_events: completions.length,
      p95_forward_ms: forwardingP95,
      p95_reply_forward_ms: percentile(
        completions.filter((row) => row.type === "chatbot_reply").map((row) =>
          row.duration
        ),
      ),
      passed: forwardingP95 <= 5000,
    };
    save("report.json", report);
    console.log(JSON.stringify(report));
    if (!report.passed) process.exitCode = 1;
  } else if (mode === "retire") {
    await api(
      `api_keys?organization_id=eq.${ctx.id}&name=eq.${ctx.integration}`,
      "DELETE",
    );
    await api(
      `organizations_addresses?organization_id=eq.${ctx.id}&address=eq.${ctx.number}`,
      "PATCH",
      { status: "disconnected" },
    );
    console.log(
      "Canary credential revoked and synthetic number disconnected; audit records retained.",
    );
  } else throw new Error("Expected bootstrap/run/verify/retire");
}
