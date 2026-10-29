import test from "node:test";
import assert from "node:assert/strict";
import { connect } from "amqplib";
import { assertTopology, names } from "../src/topology.js";
import { createConsumer, publish, publishJob } from "../src/worker.js";
import type { Backend } from "../src/backend.js";

const url = process.env.CAMPAIGN_TEST_BROKER_URL;
test(
  "local broker confirms, routes, consumes and rejects unroutable campaign jobs",
  { skip: !url, timeout: 30_000 },
  async () => {
    assert.ok(
      ["localhost", "127.0.0.1"].includes(new URL(url!).hostname),
      "integration test must never connect to a shared broker",
    );
    const connection = await connect(url!);
    const channel = await connection.createConfirmChannel();
    const topology = names(`test-scrum133-${Date.now()}`);
    try {
      await assertTopology(channel, topology);
      let processed = 0;
      let confirmRecorded = false;
      let done!: () => void;
      const completed = new Promise<void>((resolve) => {
        done = resolve;
      });
      const backend: Backend = {
        publications: async () => [],
        recover: async () => {},
        confirm: async () => {
          confirmRecorded = true;
        },
        status: async () => ({ phase: "pending" }),
        process: async () => {
          processed++;
          return { phase: "accepted" };
        },
      };
      const consumer = createConsumer(channel, topology, backend, () => done());
      await channel.consume(topology.dispatch, (message) => {
        if (message) void consumer(message);
      }, { noAck: false });
      await publishJob(channel, topology, backend, {
        version: 1,
        job_id: "10000000-0000-4000-8000-000000000001",
        organization_id: "20000000-0000-4000-8000-000000000001",
        campaign_id: "30000000-0000-4000-8000-000000000001",
        delivery_id: "40000000-0000-4000-8000-000000000001",
        publication_token: "50000000-0000-4000-8000-000000000001",
        delay_ms: 0,
      });
      await completed;
      assert.equal(confirmRecorded, true);
      assert.equal(processed, 1);
      await assert.rejects(
        publish(
          channel,
          topology,
          "unbound",
          Buffer.from("{}"),
          "unroutable-test",
        ),
        /Unroutable/,
      );
    } finally {
      for (
        const queue of [topology.dispatch, topology.retry, topology.dlq]
      ) await channel.deleteQueue(queue);
      await channel.deleteExchange(topology.exchange);
      await channel.close();
      await connection.close();
    }
  },
);
