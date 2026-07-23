# ADR 0004: Optimistic chatbot run commits

- Status: Accepted
- Date: 2026-07-23
- Related: SCRUM-14, SCRUM-57

## Context

The chatbot interpreter runs in a Deno Edge Function, while durable state and
outgoing messages live in Postgres. A database row lock cannot safely remain
open while TypeScript evaluates the flow. Concurrent or retried inbound messages
must not advance one run twice or publish messages from stale state.

## Decision

Chatbot execution uses a prepare, compute, and commit protocol:

1. `prepare_chatbot_flow_execution` serializes run creation on the conversation,
   expires overdue waiting state, rejects duplicate or stale input, and returns
   one run snapshot with its immutable definition and `lock_version`.
2. The Edge Function interprets the definition without database or network side
   effects.
3. `commit_chatbot_flow_execution` locks the run, verifies the expected
   `lock_version`, rechecks message ordering, and atomically writes the final
   run state and all outgoing text messages.

The Edge Function reloads and recomputes after a lock conflict. It never applies
a result calculated from an older snapshot.

Message ordering uses `(messages.created_at, messages.id)`, which represents
database arrival order and provides a deterministic UUID tie-breaker. Waiting
runs expire after one hour.

Each run is pinned to a same-organization AI `agent_id`. Outgoing chatbot
messages use this agent so existing message ownership and human-pause behavior
continue to distinguish automated and human responses.

## Consequences

- No database transaction stays open while Deno executes strategies.
- A committed inbound message advances a run at most once.
- Run state and generated outgoing messages succeed or roll back together.
- A failed Edge Function before commit leaves no partially emitted response.
- A conflict requires a bounded reload and recomputation.
- Phase 4 remains responsible for selecting a published version and AI agent
  when starting a live WhatsApp run.

## Deferred

- live inbound routing and agent fallback ownership;
- durable per-transition run events and replay;
- crash recovery beyond normal Edge Function delivery retries;
- buttons, lists, HTTP, AI effects, and human handoff.

## Alternatives considered

### Hold a row lock while interpreting

Rejected because the Supabase client does not hold one Postgres transaction
across arbitrary Edge Function work.

### Use a processing lease

Deferred. A lease adds timeout and recovery states that are unnecessary while
version 1 interpretation is fast and has no remote effects.

### Commit each node separately

Rejected because it creates observable partial executions and increases lock
contention. Version 1 computes through the next wait or terminal node, then
commits once.
