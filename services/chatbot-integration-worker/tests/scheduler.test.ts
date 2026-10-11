/* eslint-disable @typescript-eslint/require-await -- Async test doubles implement the production Promise interface. */
import assert from "node:assert/strict";
import test from "node:test";
import { Scheduler } from "../src/scheduler.js";
import { eventLane, eventReservation } from "../src/routing.js";
import { replyEvent, webhookEvent } from "./fixtures.js";

const tick = () => new Promise((resolve) => setImmediate(resolve));
const reservation = (keys: string[], integration = "a") => ({
  integration,
  keys,
});
test("same-customer ordering, cross-customer parallelism and multi-key atomic reservations", async () => {
  const scheduler = new Scheduler(4);
  const order: string[] = [];
  let release!: () => void;
  const first = scheduler.enqueue(reservation(["1"]), async () => {
    order.push("first");
    await new Promise<void>((resolve) => {
      release = resolve;
    });
  });
  const multi = scheduler.enqueue(reservation(["1", "2"]), async () => {
    order.push("multi");
  });
  const second = scheduler.enqueue(reservation(["2"]), async () => {
    order.push("second");
  });
  const other = scheduler.enqueue(reservation(["3"]), async () => {
    order.push("other");
  });
  await tick();
  assert.deepEqual(order, ["first", "other"]);
  release();
  await Promise.all([first, multi, second, other]);
  assert.deepEqual(order, ["first", "other", "multi", "second"]);
});
test("integration barrier blocks its tenant but not another tenant", async () => {
  const scheduler = new Scheduler(4);
  const order: string[] = [];
  let release!: () => void;
  const first = scheduler.enqueue(reservation(["1"]), async () => {
    await new Promise<void>((resolve) => {
      release = resolve;
    });
  });
  const barrier = scheduler.enqueue(reservation([]), async () => {
    order.push("barrier");
  });
  const later = scheduler.enqueue(reservation(["2"]), async () => {
    order.push("later");
  });
  const other = scheduler.enqueue(reservation(["2"], "b"), async () => {
    order.push("other");
  });
  await tick();
  assert.deepEqual(order, ["other"]);
  release();
  await Promise.all([first, barrier, later, other]);
  assert.deepEqual(order, ["other", "barrier", "later"]);
});
test("status work cannot occupy message slots; stop leaves pending jobs unexecuted", async () => {
  const messages = new Scheduler(4);
  const statuses = new Scheduler(2);
  let release!: () => void;
  const running = statuses.enqueue(
    reservation(["1"]),
    () =>
      new Promise<void>((resolve) => {
        release = resolve;
      }),
  );
  const pending = statuses.enqueue(reservation(["1"]), async () => {
    assert.fail("pending ran");
  });
  const rejected = assert.rejects(pending, /stopped/);
  await tick();
  await messages.enqueue(reservation(["1"]), async () => {});
  statuses.stop();
  release();
  await running;
  await rejected;
});
test("strict status-only classification; mixed/unknown/signed bodies remain unchanged", () => {
  const body = {
    object: "whatsapp_business_account",
    entry: [{
      changes: [{
        field: "messages",
        value: {
          metadata: { phone_number_id: "12345" },
          statuses: [{
            id: "wamid.x",
            recipient_id: "923000001",
            status: "read",
          }],
        },
      }],
    }],
  };
  const event = {
    ...webhookEvent,
    payload: {
      ...webhookEvent.payload,
      raw_body: JSON.stringify(body),
    },
  } as typeof webhookEvent;
  assert.equal(eventLane(event), "statuses");
  assert.equal(eventLane(replyEvent), "messages");
  (body.entry[0]!.changes[0]!.value as Record<string, unknown>).messages = [{
    from: "923000001",
  }];
  event.payload = {
    ...event.payload,
    raw_body: JSON.stringify(body),
  };
  assert.equal(eventLane(event), "messages");
  assert.deepEqual(eventReservation(event), {
    integration: "psdf",
    keys: ["12345:923000001"],
  });
  body.entry[0]!.changes[0]!.field = "unknown";
  event.payload = {
    ...event.payload,
    raw_body: JSON.stringify(body),
  };
  assert.equal(eventLane(event), "messages");
  assert.deepEqual(eventReservation(event).keys, []);
});
