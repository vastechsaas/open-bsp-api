import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { connect } from "amqplib";
import { integrationEventSchema } from "../src/contracts.js";
import { assertTopology, topology } from "../src/topology.js";

const fixturePath = process.argv[2];
const cloudAmqpUrl = process.env.CLOUDAMQP_URL;
if (!fixturePath || !cloudAmqpUrl) {
  console.error(
    "Usage: CLOUDAMQP_URL=<url> npm run publish:fixture -- <fixture.json>",
  );
  process.exit(1);
}

const fixture = JSON.parse(
  await readFile(resolve(fixturePath), "utf8"),
) as Record<
  string,
  unknown
>;
fixture.event_id ??= randomUUID();
fixture.occurred_at ??= new Date().toISOString();
const event = integrationEventSchema.parse(fixture);

const connection = await connect(cloudAmqpUrl);
const channel = await connection.createConfirmChannel();
await assertTopology(channel);
channel.publish(
  topology.exchange,
  topology.routingKey,
  Buffer.from(JSON.stringify(event)),
  {
    persistent: true,
    contentType: "application/json",
    messageId: event.event_id,
    timestamp: Date.now(),
    type: event.event_type,
  },
);
await channel.waitForConfirms();
console.log(JSON.stringify({ published: true, event_id: event.event_id }));
await channel.close();
await connection.close();
