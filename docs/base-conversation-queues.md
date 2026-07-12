# Base conversation queues

This document defines the first OpenBSP queue contract for the conversation
inbox. It is intentionally a base contract only: it lets the UI render Digital
Connect-style queue tabs from backend-owned configuration without introducing
advanced routing, departments, supervisor reassignment, or queue analytics.

## Goal

Conversation queue tabs should be defined by the backend, not hardcoded in the
frontend. The frontend may choose the visual treatment, but the backend owns the
queue keys, labels, order, and filtering semantics.

The base queue set is:

1. **All (active)**
2. **Assigned**
3. **Pending**
4. **Spam**
5. **Closed**
6. **Expired**

These labels match the Digital Connect reference screenshot and are the product
language for this first iteration.

## Existing OpenBSP state used by the contract

The base contract uses state that already exists in OpenBSP:

- `public.conversations.status`
- `public.conversations.assigned_agent_id`
- `public.messages.direction`
- `public.messages.timestamp`

Current assignment state is intentionally simple:

- `assigned_agent_id = null` means no human agent owns the conversation.
- `assigned_agent_id = <agent id>` means one human agent owns the conversation.

Current service-window behavior is derived from the most recent incoming message
timestamp. The MCP tool already applies the same concept when enforcing
free-form text sends: if the latest incoming message is 24 hours or older, the
service window is closed and a template is required.

## Queue contract

| Order | Key          | Label          | Filter semantics                                                                              |
| ----- | ------------ | -------------- | --------------------------------------------------------------------------------------------- |
| 1     | `all_active` | `All (active)` | Conversations where `status = 'active'`.                                                      |
| 2     | `assigned`   | `Assigned`     | Conversations where `status = 'active'` and `assigned_agent_id is not null`.                  |
| 3     | `pending`    | `Pending`      | Conversations where `status = 'active'` and `assigned_agent_id is null`.                      |
| 4     | `spam`       | `Spam`         | Conversations where `status = 'spam'`.                                                        |
| 5     | `closed`     | `Closed`       | Conversations where `status = 'closed'`.                                                      |
| 6     | `expired`    | `Expired`      | Conversations where `status = 'active'` and the latest incoming message is 24 hours or older. |

All queue queries must remain organization-scoped and must continue to respect
the existing row-level security model.

## Backend configuration shape

The backend should expose queue configuration in a shape equivalent to:

```json
[
  {
    "key": "all_active",
    "label": "All (active)",
    "order": 1,
    "enabled": true
  },
  {
    "key": "assigned",
    "label": "Assigned",
    "order": 2,
    "enabled": true
  },
  {
    "key": "pending",
    "label": "Pending",
    "order": 3,
    "enabled": true
  },
  {
    "key": "spam",
    "label": "Spam",
    "order": 4,
    "enabled": true
  },
  {
    "key": "closed",
    "label": "Closed",
    "order": 5,
    "enabled": true
  },
  {
    "key": "expired",
    "label": "Expired",
    "order": 6,
    "enabled": true
  }
]
```

The exact delivery mechanism is left for the implementation subtasks. It could
be an RPC, view, organization extra default, or another backend-owned read
model. The important contract is that queue identity and ordering come from the
backend.

## Frontend responsibilities

The frontend should:

1. Fetch or receive the queue configuration from the backend.
2. Render enabled queues in backend-provided order.
3. Use backend-provided labels.
4. Send the selected queue key when querying conversations.
5. Show an empty state when a queue has no conversations.

The frontend should not:

- hardcode the queue labels as the source of truth;
- infer undocumented queue semantics;
- introduce local-only queue keys that the backend does not understand.

## Backend filtering RPC

The backend exposes queue-aware conversation filtering through:

```sql
public.get_conversation_queue_conversations(
  p_organization_id uuid,
  p_queue_key text,
  p_limit integer default 50,
  p_offset integer default 0
)
```

The RPC returns `public.conversations` rows ordered by
`updated_at desc, id desc`. It clamps `p_limit` to the range `1..500`, treats
negative offsets as `0`, and rejects unknown queue keys with
`invalid conversation queue key`.

The RPC validates that the authenticated user can access `p_organization_id`
through the existing `get_authorized_orgs('member')` path. It does not introduce
queue-specific permissions; queue access remains organization-scoped for the
base version.

## Expired queue behavior

The `Expired` queue is the only base queue with a non-trivial prerequisite. It
depends on service-window calculation.

For this base version, `Expired` means:

1. the conversation is active, and
2. the most recent incoming message for the same organization, service,
   organization address, and contact/group address is at least 24 hours old.

If implementation discovers that this query is too expensive for the current
conversation list path, the first iteration may document and use a narrower
approximation, but the contract must state that the product meaning is the Meta
24-hour service-window boundary.

## Out of scope for the base version

The following Digital Connect-style capabilities are intentionally deferred:

- **Mentioned** queue
- **Exited** queue
- named department/team queues
- queue membership
- queue-level permissions beyond existing organization access
- auto-assignment
- round-robin assignment
- load-balanced assignment
- supervisor reassignment
- assignment history and queue analytics
- online/offline agent availability
- workload dashboards
- dedicated socket/event bus for queues
- bot-flow-driven routing

Those items require separate product and architecture decisions on top of this
base queue contract.

## Implementation sequencing

1. Define this contract.
2. Add a backend-owned queue configuration source.
3. Add queue-aware conversation filtering.
4. Render frontend tabs from backend configuration.
5. Add tests and documentation.

This sequence keeps the base queue UI useful without pulling in advanced routing
before the data model is ready.
