# Main latency canary — 2026-10-11

> Historical initial benchmark. For the subsequent live classification finding,
> representative 5.146-second result, user acceptance and actual deployment
> status, see [Main worker latency record](MAIN-WORKER-LATENCY.md). The initial
> passing result below does not establish that the later candidate is deployed
> or that the thirty-minute observation completed.

## Rollout decision: final canary passed

The initial canaries failed and prevented live rollout. After the measured
worker-only refinements below, the final complete canary passed the agreed
five-second P95 gate and restart/redelivery checks. Main rollout is authorized
by the implementation plan; the thirty-minute live observation is still pending.

The compatible `whatsapp-webhook` handler was deployed to Main. Its new path
requires a verified Meta signature, existing tenant API authentication and the
worker's status-only header. The legacy live worker does not use that path. No
database migration, frontend, Node engine, PSDF or staging change was made.

Validation passed: the complete backend suite (980 database assertions), four
focused status-handler tests, fifty worker tests, worker lint and build. The
final worker follow-up bounds broker cancellation/close RPCs so a broken
connection cannot extend the shutdown drain indefinitely. That follow-up was
tested and built locally, then exercised in the final Oracle canary.

## Test configuration

- Isolated synthetic Main organization, twenty customer/conversation mappings.
- Separate ingress/routing key, message/status/retry queues and DLQ.
- Four message slots; two status slots; Tokyo `x-region: ap-northeast-1`.
- Twenty customer/reply pairs, one hundred delivery statuses, one duplicate
  reply. Each pair was published together, followed by publisher confirmation
  and a two-second interval before the next pair.
- No Meta sends, real customer messages, human conversation actions or live
  bot/flow edits. All tests used synthetic identifiers.

## Initial results — failed, not used for rollout

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

## Refinements and final result

- The candidate's serial compatibility mode correctly drained the same load. P95
  was 99,416 ms across events and 31,647 ms for replies. This is an isolated
  serial-mode comparison, not a replay of the old live worker's workload.
- Four status slots alone: P95 9,432 ms overall / 4,075 ms replies; 29 retries.
- Known-reply prerequisites and narrower receipt ordering, four status slots:
  P95 5,882 ms overall / 3,967 ms replies; zero retries.
- Eight status slots with those refinements: P95 5,539 ms overall / 3,809 ms
  replies; zero retries. More slots alone did not meet the gate.
- Final worker also suppresses repeat HTTP calls for exact signed receipt
  payloads only after a successful verified update under the same credentials.
  Every envelope is still stored. The cache is bounded, lasts sixty seconds, and
  never handles customer/reply/handoff/lifecycle events.
- **Final four-message/four-status run:** P95 **4,949 ms across all 140 unique
  envelopes**, **3,558 ms replies**. All forty message rows were correct;
  ownership was unchanged, zero retries and zero dead-lettered events. Forty
  receipt envelopes reused a previously confirmed identical update; they are
  included in the overall percentile, not discarded from the benchmark.
- Replayed forty already persisted synthetic envelopes, stopped the worker while
  work was outstanding, restarted and verified all forty reached a successful
  outcome after replay, with no extra/missing/misrouted message rows or
  ownership changes. Unstarted deliveries recovered through the broker.
- One intermediate fixture run started publishing before its new ingress was
  bound; eight publications were unroutable. That run was invalid and excluded,
  not reported as a pass. The producer now uses mandatory publications, detects
  returns, and deployment waits for readiness before starting the benchmark.

No database-call consolidation, handler polling, schema change or relaxed
performance threshold was required. The narrow 51 ms margin means this is a
controlled-load result, not a guarantee of every real message arriving in five
seconds. Observe Main's actual load and retries for at least thirty minutes.

The previous live image and private deployment configuration were retained on
Oracle. Canary audit records and durable queues are retained; do not purge them.
Disposable test credentials/numbers must be retired and canary containers
stopped after final checks; preserve their audit records and queues.
