# Main worker latency: implementation and acceptance record

Updated 2026-10-11. This record is retained on backend **Main**. It supersedes
the rollout conclusions in `MAIN-CANARY-RESULTS.md`, which remains as the
initial benchmark history.

## Decision

The latest representative test measured **5,146 ms P95**, versus the original
**5,000 ms** target. The user accepted this approximately **5.15-second** result
on 2026-10-11 and requested that further tuning stop for now. This is acceptance
of a 146 ms overrun, not a claim that the original gate passed. Correctness
checks passed.

This documentation commit does not deploy or merge later runtime changes, change
concurrency, resume monitoring or modify customer data. Acceptance of a
benchmark is distinct from deployment of its candidate.

## Current deployment and unfinished work

| Item                                         | Recorded state                                                               |
| -------------------------------------------- | ---------------------------------------------------------------------------- |
| Live Main worker image                       | `openbsp-main-chatbot-worker:7f730ac`                                        |
| Docker start time                            | `2026-10-11T11:53:05.714Z`                                                   |
| Main source before this documentation commit | `0a76e3b`                                                                    |
| Compatible Main status-only handler          | Deployed, including known contact-metadata support                           |
| Latest representative worker candidate       | `03a4866`; tested in isolation, not deployed to the live Main worker         |
| Candidate branch                             | `codex/chatbot-worker-latency`                                               |
| Raw-storage/prerequisite overlap experiment  | Local uncommitted work; no canary result or deployment                       |
| Thirty-minute live observation               | Incomplete; follow-up monitor paused after classification mismatch was found |

A read-only readiness check during this documentation update showed connected
ingress and both lane consumers, zero active/pending tasks, 80 processed
deliveries, zero retries and zero DLQ events since startup. This is a health
snapshot, not a sustained latency measurement.

## Root cause and implemented improvements

Receipts competed with customer messages, bot replies and lifecycle work. Serial
processing and repeated inline attempts could delay later messages. Main
database-heavy requests also needed explicit Tokyo routing. Geography alone was
not established as the cause; PSDF end-to-end timings were not measured.

Implemented in the initial Main worker:

- Preserve the existing single-active-consumer ingress and unchanged original
  envelope bytes. Confirm downstream publication before acknowledging ingress.
- Add durable `.messages` and `.statuses` lanes. Code defaults: four message
  slots/two status slots. Deployed Main and latest canaries: **four/four**,
  `WORKER_MODE=parallel`.
- Strictly status-only sent/delivered/read webhooks use the status lane. Mixed
  and unfamiliar payloads remain in messages. Never rewrite signed Meta bodies.
- Reserve per-customer ordering before asynchronous processing; reserve
  multi-customer batches atomically. Unknown events use an integration barrier.
  Preserve stable event IDs, episode dependencies and ownership revisions.
- Bound storage/HTTP attempts at ten seconds. Retry transient failures durably
  after **5, 15, 30, 60 and 120 seconds**, then retain failures in the DLQ.
  Confirm retry/DLQ publication before acknowledging the original event.
- Coordinate known pending reply writes before forwarding receipts. This local
  optimization does not replace database checks or durable retries.
- Status-only handling requires existing tenant authentication and verified
  signatures. UPDATE existing messages only; missing originals are retryable.
  Never create placeholders or overwrite message content/conversation identity.
- Cache exact signed receipt confirmations only after verified successful
  updates under the same credentials: bounded to 4,096 entries/60 seconds. Every
  raw envelope is still stored. Never cache message/lifecycle processing.
- Set Main `OPENBSP_EDGE_REGION=ap-northeast-1`; log returned execution region.
  Record event age, local wait, raw-storage and forwarding times without bodies,
  credentials or customer phone numbers.
- Stop consumption and drain up to 45 seconds on shutdown; bound broker close
  calls. Docker grace period: 55 seconds. Unfinished work remains
  unacknowledged.

### Subsequent live finding and candidate-only corrections

Main's status-only webhooks include `contacts` identity metadata. The initial
strict classifier did not recognize it, so receipts used the message lane.
During limited live observation, HTTP averaged about 1,471 ms but local
scheduling wait averaged about 5,158 ms; maximum event age was 16,546 ms.
Requests ran successfully in Tokyo. Idle status consumers while receipts
occupied the message lane prompted the correction, not further regional guesses.

Candidate `1c5c2a6` recognizes only known contact identity fields; unfamiliar or
mixed payloads still use messages. Candidate `03a4866` additionally enables AMQP
`noDelay`, configures heartbeat through the URL when absent and preserves
existing URL options. **These worker corrections are not in live `7f730ac`.**
The compatible handler's metadata support has already been deployed to Main.

## Canary method and correctness

Disposable Main organization, fake number, twenty mapped conversations and
separate routing keys/queues. No real Meta sends, customer messages, live
conversation actions or DKR flow changes.

Twenty customer/reply pairs plus one hundred receipts and one duplicate reply:
**141 deliveries / 140 unique events**. Publish each pair with confirmation,
then a two-second interval. Representative fixtures include the contact and
receipt field shapes observed on Main. Wait for readiness before publishing; use
mandatory publications to detect unroutable messages.

Measure occurrence-to-successful-forwarding P95 across all 140 unique events,
including retries and confirmed exact-duplicate status outcomes. Do not discard
slow/cold requests. This is not database insertion time, pure RabbitMQ latency,
recipient delivery time or browser rendering time.

Latest run: forty correct nonempty message rows, correct mapped conversations
and lane placement, all 140 unique successful outcomes, no duplicate reply rows,
delivered/read status, unchanged ownership/revisions, zero retries and zero DLQ
events. Forty repeat receipts reused confirmed identical updates and remain
included in the percentile. Execution region was Tokyo.

## Measured results

| Experiment                                | Reply P95    | All-event P95 | Outcome                                                   |
| ----------------------------------------- | ------------ | ------------- | --------------------------------------------------------- |
| Initial four-message/two-status lanes     | 7,665 ms     | 14,007 ms     | Eight prerequisite retries; target missed                 |
| Serial compatibility comparison           | 31,647 ms    | 99,416 ms     | Correct; isolated comparison, not old live workload       |
| Four/four without prerequisite refinement | 4,075 ms     | 9,432 ms      | 29 retries; target missed                                 |
| Coordinated prerequisites, four/four      | 3,967 ms     | 5,882 ms      | Zero retries; target missed                               |
| Coordinated prerequisites, four/eight     | 3,809 ms     | 5,539 ms      | Zero retries; target missed                               |
| Exact-confirmation cache, `7f730ac`       | 3,558 ms     | 4,949 ms      | Initial gate passed; fixture lacked live contact metadata |
| Representative metadata, `1c5c2a6`        | 5,302 ms     | 6,867 ms      | Correct lanes/rows; target missed                         |
| Socket refinement, `03a4866`              | **3,869 ms** | **5,146 ms**  | Correct; user accepted original target overrun            |

One intermediate run published before ingress binding: eight publications were
unroutable. That run was invalid and excluded, never reported as a pass.
Mandatory publication checks and readiness enforcement were added afterwards.

For `7f730ac`, replayed forty persisted events, stopped with outstanding work,
then restarted. All forty had successful post-replay outcomes with no
extra/missing/misrouted message rows or ownership changes. This verifies that
image's restart path, not any later untested image.

## Validation and caveats

- Full backend validation passed: 46 database test files / 980 assertions,
  backend checks, plugin checks and associated voice-service checks.
- Latest committed candidate: 51 worker tests, build and lint passed; five
  focused status-handler tests passed.
- Local overlap experiment: 52 worker tests passed. No accepted canary result;
  its build/lint completion was not reconfirmed in this documentation update.
- No migration, generated-type change, frontend change, Node engine change, Meta
  webhook switch, DKR flow edit, PSDF or staging change.

Controlled-load results are not guarantees for every live event. A sustained
Main P95, browser-latency improvement and measured PSDF comparison are not
claimed. Database-call consolidation remains outside the implemented scope.
Before claiming the latest candidate is live, deploy it explicitly, check lane
placement and restart a full thirty-minute observation window. Separate older
backlog and low-traffic limitations in that report. Further tuning is paused.

## Files and commit trail

Worker sources: `services/chatbot-integration-worker/src/`, including routing,
scheduling, confirmed publication, topology, dependencies, forwarding, raw-event
storage, state, health and shutdown. Candidate adds `broker.ts`. Handler:
`supabase/functions/whatsapp-webhook/status_only.ts`, its tests and
authenticated entrypoint. Canary helper: `ops/main-canary.mjs`.

| Commit    | Purpose                                                          |
| --------- | ---------------------------------------------------------------- |
| `1d25f7a` | Durable lanes, concurrency, status guard and retries             |
| `089b568` | Resumable synthetic canary bootstrap                             |
| `e94b28a` | Bounded shutdown and complete forwarding gate                    |
| `512ea83` | Reply prerequisites and narrower status ordering                 |
| `2ce99ff` | Stop dependency waits on shutdown; mandatory canary publications |
| `7f730ac` | Exact verified receipt confirmation cache; live image            |
| `0a76e3b` | Initial canary/restart documentation on Main                     |
| `1c5c2a6` | Known contact metadata and representative fixtures; feature only |
| `03a4866` | AMQP socket refinement and lane assertions; feature only         |

Commit IDs document provenance but do not merge code or ensure retention after
branch deletion. Do not delete the feature branch while its unmerged candidate
or local experiment is still needed. This Main document survives branch
deletion; it is not a source-code backup of unmerged changes.

## Operations and rollback

- Oracle: `130.61.190.252`.
- Main worker: `/opt/chatbots/openbsp-main-worker`.
- Container: `openbsp-main-worker-worker-1`; localhost health port **8082**.
- Ingress: `openbsp.chatbot.main.events.v1`.
- Releases: `/opt/chatbots/openbsp-main-worker/releases/<commit>`.
- Private backups:
  `/opt/chatbots/openbsp-main-worker/backups/20261011-worker-latency`.

Read-only checks after SSH login:

```sh
curl -fsS http://127.0.0.1:8082/readyz
sudo docker inspect --format '{{.Config.Image}} {{.State.Status}} {{.State.StartedAt}}' openbsp-main-worker-worker-1
```

Retain original image `openbsp-main-chatbot-worker:8886b26`, deployed `7f730ac`
and private Compose/environment backups. Never run old/new competing live
consumers or purge queues. Rollback uses the lane-compatible image with
`WORKER_MODE=serial` to drain both lanes and retries before restoring an older
image unable to consume them. Keep the compatible handler during drainage. Do
not modify histories, ownership, Node configuration or webhooks on rollback.

Keep private directories/files restricted to 700/600. Never copy `.env`, canary
input/context files, raw bodies, tokens or unrestricted logs into documentation.
Retain audit records and durable queues. Retire disposable API keys, disconnect
fake numbers and stop canary containers after checks; the representative/socket
canaries still need that housekeeping at this record. This documentation update
performs no deployment or cleanup.
