# ADR 0002: Base conversation queues

- Status: Proposed
- Date: 2026-07-12
- Related: SCRUM-25, SCRUM-26

## Context

Digital Connect shows operational queues at the top of the conversation screen:
All (active), Assigned, Pending, Spam, Closed, and Expired. Senior feedback is
that these queues should be configurable from the backend rather than hardcoded
in the frontend.

OpenBSP already has the first assignment foundation:

- `public.conversations.assigned_agent_id` stores the current optional human
  assignee.
- `public.conversations.status` stores conversation lifecycle state as text.
- service-window behavior is currently derived from latest incoming message
  timestamps when sending free-form messages.

The system does not yet have department queues, queue membership,
auto-assignment, assignment history, or supervisor reassignment.

## Decision

Add a backend-owned base queue contract for the conversation inbox.

The first queue set is:

1. **All (active)**
2. **Assigned**
3. **Pending**
4. **Spam**
5. **Closed**
6. **Expired**

The backend owns queue keys, labels, order, enabled state, and filter semantics.
The frontend renders the queues from backend-provided configuration and uses the
selected queue key to request the matching conversation list.

## Queue semantics

| Queue        | Semantics                                                               |
| ------------ | ----------------------------------------------------------------------- |
| All (active) | `conversations.status = 'active'`                                       |
| Assigned     | active conversations where `assigned_agent_id is not null`              |
| Pending      | active conversations where `assigned_agent_id is null`                  |
| Spam         | `conversations.status = 'spam'`                                         |
| Closed       | `conversations.status = 'closed'`                                       |
| Expired      | active conversations whose latest incoming message is 24 hours or older |

All filters remain organization-scoped and use the existing authorization/RLS
model.

## Consequences

- The frontend can match the Digital Connect queue layout without owning queue
  definitions.
- Future queue labels or ordering can be changed in one backend-owned place.
- The queue contract builds on the completed base assignment work without
  expanding it into routing or queue analytics.
- `Expired` requires careful implementation because OpenBSP currently derives
  the service window from messages rather than storing
  `service_window_expires_at` on `conversations`.
- `Spam` and `Closed` require consistent use of `conversations.status` values.

## Alternatives considered

### Keep queue tabs hardcoded in the frontend

Rejected. This would make Digital Connect-style behavior brittle and would
require frontend changes for labels, ordering, and customer-specific queue
visibility.

### Implement full routing queues now

Rejected for the base version. Department queues, auto-routing, round-robin,
supervisor reassignment, and assignment history need additional schema and
product decisions. Adding them now would over-expand the current feature slice.

### Add a separate assignment/queue table immediately

Deferred. A separate queue/routing table may be useful later for advanced
routing and analytics. The base queue set can be derived from existing
conversation and message state, so a new table is not required for this first
contract.

## Out of scope

- Mentioned queue
- Exited queue
- department/team queues
- queue membership
- auto-assignment
- round-robin or load-balanced assignment
- supervisor reassignment
- assignment history and analytics
- queue-specific realtime event bus
- bot-flow-driven routing

## Reference

See [`../base-conversation-queues.md`](../base-conversation-queues.md).
