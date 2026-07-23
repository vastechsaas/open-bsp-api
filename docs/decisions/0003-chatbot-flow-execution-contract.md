# ADR 0003: Chatbot flow execution contract

- Status: Accepted
- Date: 2026-07-23
- Related: SCRUM-14, SCRUM-54

## Context

OpenBSP needs a visual chatbot builder without coupling runtime behavior to
React Flow. React Flow owns editor concerns such as positions, selection,
dimensions, handles, and presentation metadata. Those fields are useful while
editing, but they are not a stable or safe execution API.

The schema foundation separates the mutable editor graph from an immutable
published definition. The next boundary must describe how that definition is
interpreted and how node behavior communicates with a future engine.

## Decision

Version 1 uses a database-backed State Machine, a definition Interpreter, and
Strategy handlers for node behavior.

- The State Machine records progress in `chatbot_flow_runs`.
- The Interpreter loads one immutable `chatbot_flow_versions.definition`.
- A Strategy handler implements one supported node type.
- The engine owns persistence, locking, deduplication, and outgoing commands.
- Strategies receive data and return a result. They do not call WhatsApp, mutate
  database records, or call external services directly.

The editor graph is compiled and validated before publication. Runtime never
executes the raw React Flow graph.

## Version 1 scope

The initial executable contract supports only:

1. `start`
2. `send_message`
3. `collect_input`
4. `condition`
5. `end`

Node and edge identifiers are stable routing keys. Display labels are content
and never determine a transition.

The executable definition contains:

- `schema_version: 1`;
- one `start_node_id`;
- typed runtime nodes;
- typed default and conditional edges.

## Runtime states

Version 1 uses the states already enforced by `chatbot_flow_runs`:

| Status       | Meaning                                                |
| ------------ | ------------------------------------------------------ |
| `running`    | The engine may execute automatic nodes.                |
| `waiting`    | Execution is paused for customer input.                |
| `completed`  | The flow reached an end node successfully.             |
| `failed`     | Execution stopped because of a terminal error.         |
| `handed_off` | Automated execution yielded to a human or agent owner. |
| `expired`    | The waiting session exceeded its allowed lifetime.     |

For the MVP, `waiting_for` is `free_text`. Button and list input types are added
in a later phase without changing the meaning of `waiting`.

`pending_effect` is not a version 1 database status. External HTTP and AI work
requires a later effect contract and, if necessary, a forward-only schema
migration.

## Strategy result contract

A strategy returns one of these result categories:

| Result           | Engine responsibility                                        |
| ---------------- | ------------------------------------------------------------ |
| `advance`        | Persist variable updates and move to the next node.          |
| `emit_message`   | Persist a text-message command and move to the next node.    |
| `wait_for_input` | Persist the prompt and expected free-text input, then pause. |
| `complete`       | Mark the run completed with an end timestamp.                |
| `fail`           | Persist a safe error and mark the run failed.                |

The result describes intent only. The future engine converts that intent into
database state and message records.

## Required invariants

- A run remains pinned to the version with which it started.
- Published definitions are immutable.
- An inbound message advances a run at most once.
- Only one chatbot, AI agent, or human owns the response path.
- Runtime definitions contain no arbitrary JavaScript, SQL, or template code.
- Invalid editor graphs produce structured validation issues and cannot be
  published.
- Automatic traversal is bounded by the future engine even though cycles are
  rejected by the MVP compiler.

## Deferred

- button and list input;
- dynamic template interpolation;
- HTTP and AI effects;
- circuit-breaker state;
- subflows, loops, parallel branches, and joins;
- the chatbot Edge Function and database transition RPCs;
- WhatsApp webhook routing and interactive-message dispatch;
- run event history, replay, and operational metrics.

## Consequences

- The frontend and backend share one versioned runtime language.
- Editor-only changes cannot silently change execution semantics.
- Node behavior can be developed and tested independently.
- External side effects stay behind one engine-controlled boundary.
- Adding a node type requires an explicit schema and strategy extension rather
  than another branch in a monolithic executor.

## Alternatives considered

### Execute the React Flow graph directly

Rejected. Editor metadata is not a stable runtime contract and would couple
published behavior to frontend-library details.

### Store executable JavaScript in a node

Rejected. It would make validation, isolation, authorization, and deterministic
replay substantially harder.

### Implement one large node-type switch

Rejected. It would mix orchestration and node behavior and make later HTTP, AI,
and handoff behavior difficult to isolate and test.

## Reference

See [`../chatbot-flow-development.md`](../chatbot-flow-development.md).
