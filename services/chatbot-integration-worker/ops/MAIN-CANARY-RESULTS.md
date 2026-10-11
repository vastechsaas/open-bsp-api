# Main latency canary — 2026-10-11

## Rollout decision: STOP

Do not merge/deploy the live Main worker from this branch yet. The controlled
canary failed the agreed five-second P95 forwarding gate. There was no Main
worker rollout or thirty-minute post-rollout observation.

The compatible `whatsapp-webhook` handler was deployed to Main. Its new path
requires a verified Meta signature, existing tenant API authentication and the
worker's status-only header. The legacy live worker does not use that path. No
database migration, frontend, Node engine, PSDF or staging change was made.

Validation passed: the complete backend suite (980 database assertions), four
focused status-handler tests, forty-five worker tests, worker lint and build.
The final worker follow-up bounds broker cancellation/close RPCs so a broken
connection cannot extend the shutdown drain indefinitely. That follow-up was
tested and built locally; it was not deployed to the failed canary or Main.

## Test configuration

- Isolated synthetic Main organization, twenty customer/conversation mappings.
- Separate ingress/routing key, message/status/retry queues and DLQ.
- Four message slots; two status slots; Tokyo `x-region: ap-northeast-1`.
- Twenty customer/reply pairs, one hundred delivery statuses, one duplicate
  reply. Each pair was published together, followed by publisher confirmation
  and a two-second interval before the next pair.
- No Meta sends, real customer messages, human conversation actions or live
  bot/flow edits. All tests used synthetic identifiers.

## Results

| Check                                           | Result                                  |
| ----------------------------------------------- | --------------------------------------- |
| Expected message rows                           | 40/40, nonempty content                 |
| Conversation routing                            | All twenty mapped conversations correct |
| Duplicate reply                                 | No duplicate message row                |
| Ownership                                       | No ownership/revision changes           |
| Delivered/read status                           | Present on all twenty replies           |
| Unique events forwarded successfully            | 140/140                                 |
| Worker deliveries completed                     | 141, including the duplicate            |
| Durable prerequisite retries                    | 8                                       |
| Dead-lettered events                            | 0                                       |
| Actual Edge execution region                    | `ap-northeast-1`                        |
| P95 database insertion, customer/reply messages | 6,221 ms                                |
| P95 completed forwarding, replies               | 7,665 ms                                |
| P95 completed forwarding, all unique events     | 14,007 ms — **FAIL**                    |

Insertion timestamps precede HTTP completion and are not the rollout gate. The
operator script now correlates stored raw events with successful HTTP completion
logs, including durable retries. All events, not only fast/warm ones, are
included. Duplicate deliveries are checked for correctness but not counted as
additional unique events in the percentile.

## Remaining bottlenecks

First reply handler requests took approximately 2.7–3.3 seconds; later ones were
approximately one second. Startup/cold execution is a hypothesis, not a
confirmed sole cause. Customer serialization caused subsequent same-customer
replies to wait for the initial inbound handler to complete.

Status processing averaged 1,037 ms per attempt (including raw storage), with
two slots. Under this load it accumulated a mean local scheduling wait of 2,649
ms. Statuses that preceded message persistence correctly received 503 and
retried after five seconds instead of creating empty placeholders.

Message processing averaged 1,545 ms per attempt; mean raw storage was 415 ms.
These are worker/HTTP/storage measurements, not pure RabbitMQ latency and not
browser rendering latency.

## Next work before any rollout

1. Measure a like-for-like serial baseline using another isolated fixture.
2. Tune bounded status capacity from measured throughput and retest without
   weakening the five-second gate or excluding initial requests/retries.
3. Investigate slow initial Edge calls and status prerequisites. If meeting the
   gate requires consolidating database calls or changing handler contracts,
   agree that additional scope before implementing it; this plan explicitly
   excluded database-call consolidation initially.
4. Verify restart/redelivery and serial compatibility mode using only isolated
   queues, then rerun the entire correctness/performance canary.
5. Only after a pass: merge Main, stop the legacy live worker, deploy the new
   worker, and observe normal traffic for at least thirty minutes.

The previous live image and private deployment configuration were retained on
Oracle. Canary audit records and durable queues are retained; do not purge them.
The disposable API key was revoked, its fake number disconnected, and the canary
container stopped. The live Main worker is still running its original image.
