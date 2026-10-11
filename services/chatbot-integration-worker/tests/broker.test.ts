import assert from "node:assert/strict";
import test from "node:test";
import { brokerConnection } from "../src/broker.js";

test("disables packet coalescing and negotiates heartbeat without changing broker/vhost credentials", () => {
  const config = brokerConnection(
    "amqps://user:p%40ss@example.com/tenant?frameMax=131072",
  );
  const url = new URL(config.url);
  assert.equal(url.username, "user");
  assert.equal(url.password, "p%40ss");
  assert.equal(url.pathname, "/tenant");
  assert.equal(url.searchParams.get("frameMax"), "131072");
  assert.equal(url.searchParams.get("heartbeat"), "15");
  assert.equal(config.socket.noDelay, true);
  assert.equal(config.socket.keepAlive, true);
  assert.equal(config.socket.timeout, 10_000);
  assert.equal(
    new URL(brokerConnection("amqps://example.com/vhost?heartbeat=30").url)
      .searchParams.get("heartbeat"),
    "30",
  );
});
