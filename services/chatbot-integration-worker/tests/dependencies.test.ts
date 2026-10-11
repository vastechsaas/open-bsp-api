import assert from "node:assert/strict";
import test from "node:test";
import { ReplyDependencies } from "../src/dependencies.js";
import { conflicts, eventReservation } from "../src/routing.js";
import { replyEvent, webhookEvent } from "./fixtures.js";

function statusEvent(status = "read", id = replyEvent.payload.wamid) {
  return {
    ...webhookEvent,
    payload: {
      ...webhookEvent.payload,
      raw_body: JSON.stringify({
        object: "whatsapp_business_account",
        entry: [{
          changes: [{
            field: "messages",
            value: {
              metadata: { phone_number_id: replyEvent.payload.phone_number_id },
              statuses: [{
                id,
                status,
                recipient_id: replyEvent.payload.recipient,
                timestamp: "1",
              }],
            },
          }],
        }],
      }),
    },
  };
}
test("known pending replies settle before status work without holding a processing slot", async () => {
  const dependencies = new ReplyDependencies();
  dependencies.reserve(replyEvent);
  dependencies.reserve(replyEvent); // redelivery shares its prerequisite
  let started = false;
  const waiting = dependencies.wait(statusEvent()).then(() => {
    started = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(started, false);
  dependencies.complete(replyEvent);
  await waiting;
  assert.equal(started, true);
  dependencies.dispose();
});
test("unknown, other tenant/number/customer and non-status events never inherit another wait", async () => {
  const dependencies = new ReplyDependencies();
  dependencies.reserve(replyEvent);
  await dependencies.wait(statusEvent("read", "wamid.other"));
  await dependencies.wait({ ...statusEvent(), integration_key: "different" });
  await dependencies.wait(replyEvent);
  await dependencies.wait(webhookEvent);
  dependencies.dispose();
});
test("failed or interrupted writes release bounded waits and retain database verification", async () => {
  const dependencies = new ReplyDependencies(1);
  dependencies.reserve(replyEvent);
  await dependencies.wait(statusEvent()); // timeout: handler must verify/retry
  dependencies.reserve(replyEvent);
  const waiting = dependencies.wait(statusEvent());
  dependencies.dispose(); // reconnect/shutdown: no stuck jobs or timers
  await waiting;
  dependencies.reserve(replyEvent); // late ingress cannot extend shutdown
  await dependencies.wait(statusEvent());
});
test("different receipt fields/messages can run concurrently while identical fields remain ordered", () => {
  const read = eventReservation(statusEvent());
  assert.equal(conflicts(read, eventReservation(statusEvent("read"))), true);
  assert.equal(conflicts(read, eventReservation(statusEvent("sent"))), false);
  assert.equal(
    conflicts(read, eventReservation(statusEvent("read", "wamid.other"))),
    false,
  );
});
