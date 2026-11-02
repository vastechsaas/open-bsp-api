const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const amqp = require("amqplib");
const { basePrisma: db, pool } = require("./dist/core/config/db.js");
const { encrypt } = require("./dist/core/utils/crypto.js");
const companyId = 141141n;
const phone = "141141000000001";
let broker;
let channel;
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function main() {
  assert.equal(
    process.env.OPENBSP_EXCHANGE,
    "openbsp.staging.campaign-receipts.verify",
    "Not isolated receipt staging",
  );
  assert.equal(
    new URL(process.env.OPENBSP_AMQP_URL).hostname,
    "rabbitmq",
    "No external broker in this verification",
  );
  const previous = await db.company.findUnique({ where: { id: companyId } });
  assert.ok(
    !previous || previous.name === "Campaign receipt verification",
    "Fixture identity collision",
  );
  if (!previous) {
    await db.company.create({
      data: {
        id: companyId,
        name: "Campaign receipt verification",
        email: "campaign-receipt-fixture@example.invalid",
        active: true,
        botEnabled: false,
        serviceCredentialHash: crypto.createHash("sha256").update(
          crypto.randomBytes(32),
        ).digest("hex"),
        wabaAccount: {
          create: {
            phoneNumber: "15550001411",
            phoneNumberId: phone,
            wabaId: "141141000000002",
            accessToken: encrypt("synthetic-no-send-token-for-staging-only"),
            isActive: false,
            accountSuspended: true,
            connectionState: "DISCONNECTED",
          },
        },
      },
    });
  }
  await db.company.update({
    where: { id: companyId },
    data: { active: true, botEnabled: false },
  });
  await db.wabaAccount.update({
    where: { companyId },
    data: { isActive: false, accountSuspended: true },
  });
  broker = await amqp.connect(process.env.OPENBSP_AMQP_URL);
  channel = await broker.createChannel();
  await channel.assertExchange(process.env.OPENBSP_EXCHANGE, "topic", {
    durable: true,
  });
  const queue = await channel.assertQueue("", { exclusive: true });
  await channel.bindQueue(
    queue.queue,
    process.env.OPENBSP_EXCHANGE,
    process.env.OPENBSP_ROUTING_KEY,
  );
  const run = crypto.randomUUID();
  async function exercise(label, duplicate) {
    const raw = JSON.stringify({
      object: "whatsapp_business_account",
      entry: [{
        id: "141141000000002",
        changes: [{
          field: "messages",
          value: {
            messaging_product: "whatsapp",
            metadata: {
              phone_number_id: phone,
              display_phone_number: "15550001411",
            },
            messages: [{
              from: "15550001412",
              id: `wamid.fixture.input.${run}.${label}`,
              timestamp: String(Math.floor(Date.now() / 1000)),
              type: "text",
              text: { body: "Synthetic inactive input: do not execute" },
            }],
            statuses: [{
              id: `wamid.fixture.receipt.${run}.${label}`,
              recipient_id: "15550001412",
              timestamp: String(Math.floor(Date.now() / 1000)),
              status: "read",
            }],
          },
        }],
      }],
    });
    const signature = `sha256=${
      crypto.createHmac("sha256", process.env.META_APP_SECRET).update(raw)
        .digest("hex")
    }`;
    for (let n = 0; n < (duplicate ? 2 : 1); n++) {
      const response = await fetch("http://api:4080/api/v1/webhooks/meta", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-hub-signature-256": signature,
        },
        body: raw,
      });
      assert.equal(response.status, 200, "Signed webhook not durably queued");
    }
    let message;
    for (let n = 0; n < 150 && !message; n++) {
      message = await channel.get(queue.queue, { noAck: false });
      if (!message) await pause(200);
    }
    assert.ok(message, "Receipt not forwarded to private staging queue");
    const envelope = JSON.parse(message.content.toString());
    assert.equal(envelope.event_type, "whatsapp_webhook");
    assert.equal(envelope.payload.raw_body, raw, "Signed body was changed");
    assert.equal(envelope.payload.x_hub_signature_256, signature);
    assert.equal(envelope.payload.receipts_only, true);
    channel.ack(message);
    const events = await db.integrationEvent.findMany({
      where: {
        companyId,
        kind: "whatsapp_webhook",
        deduplicationKey: `webhook:${
          crypto.createHash("sha256").update(raw).digest("hex")
        }`,
      },
    });
    assert.equal(events.length, 1, "Duplicate webhook created another event");
  }
  await exercise("disconnected", true);
  await db.company.update({
    where: { id: companyId },
    data: { active: false },
  });
  await db.wabaAccount.update({
    where: { companyId },
    data: { isActive: true },
  });
  await exercise("suspended", false);
  assert.equal(
    await db.flowExecution.count({ where: { companyId } }),
    0,
    "Bot executed",
  );
  assert.equal(
    await db.outboundDispatch.count({ where: { companyId } }),
    0,
    "Outbound reply planned",
  );
  assert.equal(
    await db.conversation.count({ where: { companyId } }),
    0,
    "Inactive input created a chat",
  );
  await db.wabaAccount.update({
    where: { companyId },
    data: { isActive: false },
  });
  console.log(
    JSON.stringify({
      event: "staging_receipt_verification_passed",
      tenant: String(companyId),
      signed_receipts: 2,
      duplicate_delivery_checked: true,
      original_bytes_preserved: true,
      bot_executions: 0,
      outbound_dispatches: 0,
      conversations: 0,
      meta_sends: 0,
    }),
  );
}
main().catch((error) => {
  console.error(
    JSON.stringify({
      event: "staging_receipt_verification_failed",
      code: error.name,
      reason: error instanceof assert.AssertionError
        ? error.message
        : "Inspect isolated staging logs",
    }),
  );
  process.exitCode = 1;
})
  .finally(async () => {
    if (channel) await channel.close();
    if (broker) await broker.close();
    await db.$disconnect();
    await pool.end();
  });
