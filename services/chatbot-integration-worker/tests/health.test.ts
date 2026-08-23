import assert from "node:assert/strict";
import test from "node:test";
import type { AddressInfo } from "node:net";
import { startHealthServer } from "../src/health.js";
import { createWorkerState } from "../src/state.js";

test("health stays alive while readiness follows the RabbitMQ consumer", async () => {
  const state = createWorkerState();
  const server = await startHealthServer(state, 0);
  const port = (server.address() as AddressInfo).port;
  assert.equal((await fetch(`http://127.0.0.1:${port}/healthz`)).status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${port}/readyz`)).status, 503);
  state.connected = true;
  state.consuming = true;
  assert.equal((await fetch(`http://127.0.0.1:${port}/readyz`)).status, 200);
  state.shuttingDown = true;
  assert.equal((await fetch(`http://127.0.0.1:${port}/readyz`)).status, 503);
  await new Promise<void>((resolve) => server.close(() => resolve()));
});
