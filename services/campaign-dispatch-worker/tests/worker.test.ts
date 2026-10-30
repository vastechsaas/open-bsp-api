import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { createConsumer, publishJob } from "../src/worker.js";
import { type Job, jobSchema, loadConfig } from "../src/contracts.js";
import { names } from "../src/topology.js";
import { type Backend, createBackend } from "../src/backend.js";

const job: Job = {
  version: 1,
  job_id: "10000000-0000-4000-8000-000000000001",
  organization_id: "20000000-0000-4000-8000-000000000001",
  campaign_id: "30000000-0000-4000-8000-000000000001",
  delivery_id: "40000000-0000-4000-8000-000000000001",
};
const topology = names("staging");
function fixture() {
  const calls: string[] = [];
  const events = new EventEmitter();
  const published: Array<Record<string, unknown>> = [];
  const fake = Object.assign(events, {
    publish(
      _exchange: string,
      route: string,
      bytes: Buffer,
      options: Record<string, unknown>,
      callback: (err?: Error) => void,
    ) {
      calls.push(route);
      published.push(JSON.parse(bytes.toString()) as Record<string, unknown>);
      assert.equal(options.mandatory, true);
      assert.equal(options.persistent, true);
      callback();
      return true;
    },
    ack() {
      calls.push("ack");
    },
  });
  const backend: Backend = {
    publications: async () => [],
    confirm: async () => {
      calls.push("confirm");
    },
    recover: async () => {},
    status: async () => ({ phase: "pending" }),
    process: async () => {
      calls.push("process");
      return { phase: "accepted" };
    },
  };
  const channel = fake as unknown as ConfirmChannel;
  const message = (value: unknown) =>
    ({
      content: Buffer.from(JSON.stringify(value)),
      properties: {},
    }) as ConsumeMessage;
  return { calls, published, backend, channel, fake, message };
}
test("environment namespaces never bind campaign work to chatbot or production queues", () => {
  assert.notEqual(names("staging").dispatch, names("production").dispatch);
  assert.ok(!topology.dispatch.includes("chatbot"));
});
test("strict identifier envelope rejects credentials/content", () => {
  assert.equal(
    jobSchema.safeParse({ ...job, access_token: "secret" }).success,
    false,
  );
});
test("publisher strips lease data and confirms broker before durable publication mark", async () => {
  const f = fixture();
  await publishJob(f.channel, topology, f.backend, {
    ...job,
    publication_token: job.job_id,
    delay_ms: 500,
  });
  assert.deepEqual(f.calls, ["retry", "confirm"]);
  assert.deepEqual(f.published, [job]);
});
test("unroutable publish is not marked complete", async () => {
  const f = fixture();
  f.fake.publish = (_exchange, _route, _body, options, cb) => {
    f.fake.emit("return", { properties: options });
    cb();
    return true;
  };
  await assert.rejects(
    publishJob(f.channel, topology, f.backend, {
      ...job,
      publication_token: job.job_id,
      delay_ms: 0,
    }),
  );
  assert.ok(!f.calls.includes("confirm"));
});
test("accepted job acknowledgment follows durable backend disposition", async () => {
  const f = fixture();
  await createConsumer(f.channel, topology, f.backend, () => {})(
    f.message(job),
  );
  assert.deepEqual(f.calls, ["process", "ack"]);
});
test("redelivered accepted job never invokes send handler", async () => {
  const f = fixture();
  f.backend.status = async () => ({ phase: "accepted" });
  await createConsumer(f.channel, topology, f.backend, () => {})(
    f.message(job),
  );
  assert.deepEqual(f.calls, ["ack"]);
});
test("HTTP timeout reconciles accepted result without second POST", async () => {
  const f = fixture();
  let reads = 0;
  f.backend.status = async () => ({
    phase: ++reads === 1 ? "pending" : "accepted",
  });
  f.backend.process = async () => {
    f.calls.push("process");
    throw new Error("timeout");
  };
  await createConsumer(f.channel, topology, f.backend, () => {})(
    f.message(job),
  );
  assert.deepEqual(f.calls, ["process", "ack"]);
});
test("outage transfers identifier-only job to durable retry before ack", async () => {
  const f = fixture();
  f.backend.status = async () => {
    throw new Error("offline");
  };
  await createConsumer(f.channel, topology, f.backend, () => {})(
    f.message(job),
  );
  assert.deepEqual(f.calls, ["retry", "ack"]);
  assert.deepEqual(f.published, [job]);
});
test("uncertainty goes to DLQ without another send", async () => {
  const f = fixture();
  f.backend.status = async () => ({ phase: "needs_review" });
  await createConsumer(f.channel, topology, f.backend, () => {})(
    f.message(job),
  );
  assert.deepEqual(f.calls, ["dlq", "ack"]);
});
test("malformed messages cannot leak secret payloads into DLQ", async () => {
  const f = fixture();
  await createConsumer(f.channel, topology, f.backend, () => {})(
    f.message({ access_token: "do-not-copy" }),
  );
  assert.ok(!JSON.stringify(f.published).includes("do-not-copy"));
  assert.deepEqual(f.calls, ["dlq", "ack"]);
});
test("backend client never retries a process POST implicitly", async () => {
  let calls = 0;
  const backend = createBackend(
    "https://example.test",
    "test-key",
    async () => {
      calls++;
      throw new Error("timeout");
    },
  );
  await assert.rejects(backend.process(job));
  assert.equal(calls, 1);
});
test("configuration rejects environment/project mismatch", () => {
  assert.throws(() =>
    loadConfig({
      DEPLOYMENT_ENV: "staging",
      SUPABASE_URL: "https://buvjopvpkgvzhykwsxnk.supabase.co",
      CLOUDAMQP_URL: "amqps://example.test",
      SUPABASE_SERVICE_ROLE_KEY: "x".repeat(30),
    })
  );
});

test("production configuration pins Main and isolates every queue", () => {
  const config = loadConfig({
    DEPLOYMENT_ENV: "production",
    SUPABASE_URL: "https://buvjopvpkgvzhykwsxnk.supabase.co",
    CLOUDAMQP_URL: "amqps://example.test",
    SUPABASE_SERVICE_ROLE_KEY: "x".repeat(30),
    EDGE_FUNCTIONS_TOKEN: "y".repeat(30),
  });
  assert.equal(config.environment, "production");
  assert.equal(config.url, "https://buvjopvpkgvzhykwsxnk.supabase.co");
  for (const key of ["exchange", "dispatch", "retry", "dlq"] as const) {
    assert.notEqual(names("production")[key], names("staging")[key]);
    assert.match(names("production")[key], /^openbsp\.production\.campaign\./);
  }
  assert.throws(() =>
    loadConfig({
      DEPLOYMENT_ENV: "production",
      SUPABASE_URL: "https://acifbsuxmpdtlhbsvhlj.supabase.co",
      CLOUDAMQP_URL: "amqps://example.test",
      SUPABASE_SERVICE_ROLE_KEY: "x".repeat(30),
    })
  );
});

test("dispatch and database credentials remain separate", async () => {
  const headers: Headers[] = [];
  const backend = createBackend(
    "https://example.test",
    "database-key",
    async (_url, init) => {
      headers.push(new Headers(init?.headers));
      return Response.json({ phase: "accepted" });
    },
    "internal-dispatch-key",
  );
  await backend.process(job);
  await backend.recover();
  assert.equal(
    headers[0]?.get("Authorization"),
    "Bearer internal-dispatch-key",
  );
  assert.equal(headers[0]?.get("apikey"), "database-key");
  assert.equal(headers[1]?.get("Authorization"), "Bearer database-key");
});
