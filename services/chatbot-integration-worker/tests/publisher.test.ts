import assert from "node:assert/strict";
import test from "node:test";
import { EventEmitter } from "node:events";
import type { ConfirmChannel } from "amqplib";
import { createConfirmedPublisher } from "../src/publisher.js";

test("individual confirmations are safe when concurrent and unroutable returns fail", async () => {
  const callbacks: Array<(error?: Error) => void> = [];
  const props: Array<{ correlationId: string }> = [];
  const channel = Object.assign(new EventEmitter(), {
    sendToQueue: (
      _queue: string,
      _body: Buffer,
      properties: { correlationId: string },
      callback: (error?: Error) => void,
    ) => {
      props.push(properties);
      callbacks.push(callback);
      return true;
    },
  });
  const publish = createConfirmedPublisher(
    channel as unknown as ConfirmChannel,
  );
  const first = publish("a", Buffer.from("a"));
  const second = publish("b", Buffer.from("b"));
  const rejected = assert.rejects(second, /publication failed/);
  channel.emit("return", { properties: props[1] });
  callbacks[1]!();
  callbacks[0]!();
  await first;
  await rejected;
});
