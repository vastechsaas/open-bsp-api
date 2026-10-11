import assert from "node:assert/strict";
import test from "node:test";
import { settleWithin } from "../src/deadline.js";

test("broken broker RPCs cannot extend shutdown indefinitely", async () => {
  assert.equal(await settleWithin(new Promise(() => {}), 1), false);
});

test("completed and failed RPCs settle without leaving a timeout behind", async () => {
  assert.equal(await settleWithin(Promise.resolve(), 60_000), true);
  assert.equal(
    await settleWithin(Promise.reject(new Error("closed")), 60_000),
    true,
  );
});
