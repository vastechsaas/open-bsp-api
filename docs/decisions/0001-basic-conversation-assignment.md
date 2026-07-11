# ADR 0001: Basic conversation assignment

- Status: Proposed
- Date: 2026-07-11
- Jira: SCRUM-7
- Parent story: SCRUM-6

## Context

OpenBSP conversations currently belong to an organization but have no human
owner. The first assignment iteration only needs to distinguish conversations
assigned to the signed-in human agent from conversations that are unassigned.

The reference project models current ownership as an optional assignment and
exposes basic assigned and pending views. Its conversation UI is partly backed
by an in-memory mock adapter, so it is behavioral input rather than an
architecture to copy.

OpenBSP already has the concepts needed for a smaller native design:

- `public.conversations` is organization-scoped and already participates in
  Supabase realtime updates.
- `public.agents` represents both human and AI agents.
- A signed-in human agent is already identified by `organization_id`, the
  authenticated `user_id`, and `ai = false`.
- Existing conversation behavior such as Pending, 24h, Archived, pinning,
  messaging, and drafts is independent of assignment.

## Decision

### Storage

Add one nullable `assigned_agent_id` column to `public.conversations`.

- `null` means the conversation is unassigned.
- A non-null value identifies the one current human assignee.
- The value references `public.agents.id`.
- The referenced agent must belong to the same organization as the
  conversation.
- The referenced agent must be a human agent (`ai = false`) with an associated
  user.

Use a column on `conversations`, not a separate assignment table. A separate
table would only add joins and lifecycle management while the base requirement
has one optional current value and no assignment history.

### Tenant integrity

Same-organization assignment is a database invariant, not a UI convention.
The schema implementation must enforce that the conversation's
`organization_id` and the assignee's `organization_id` match. The intended
relational shape is a composite relationship using organization and agent IDs,
with any supporting unique constraint added to `agents`.

The relational constraint enforces tenant membership. The guarded assignment
operations enforce that the target row is a human agent with an associated
user; a foreign key alone cannot express `ai = false`.

RLS continues to determine which organization's conversations and agents a
caller may access. The relationship constraint prevents a permitted update to
one organization from referencing an agent in another organization.

### Delete behavior

Deleting the assigned human-agent row sets only `assigned_agent_id` to `null`;
the conversation's `organization_id` remains unchanged.

The conversation and its messages must remain available. Requiring manual
unassignment before removing an organization member would couple member
management to the inbox unnecessarily at this stage.

### Eligible actor and operations

The base public workflow has two operations:

1. **Assign to me:** an authenticated organization member with a current human
   agent may change an unassigned conversation from `null` to their own agent
   ID.
2. **Unassign:** the same human agent may change a conversation assigned to
   them from their agent ID to `null`.

The base workflow does not allow selecting another agent, taking over a
conversation assigned to someone else, or assigning an AI agent.

The implementation must validate these transitions at the database boundary;
the UI must not be the only enforcement point. A claim should update only an
unassigned row, and an unassign should update only a row owned by the current
agent. If the row no longer matches that condition, the operation returns a
normal conflict/no-change result and refreshes the current state. This is basic
write correctness, not a queue or locking subsystem.

### Read behavior

The base UI may derive two additional views from the assignee value:

- **Mine:** `assigned_agent_id` equals the signed-in human agent's ID.
- **Unassigned:** `assigned_agent_id` is `null`.

These views supplement rather than replace the existing All, Pending, 24h, and
Archived behavior. Assignment does not change message unread state, service
window state, archive state, or conversation status.

### Realtime behavior

Assignment uses the existing conversation row and existing Supabase realtime
pipeline. No assignment-specific event bus, presence channel, queue counter, or
socket layer is introduced. When `assigned_agent_id` changes, the existing
conversation state should update and the Mine/Unassigned views should be
re-evaluated.

## Consequences

### Positive

- Minimal schema and UI surface.
- Reuses current OpenBSP tenant, agent, conversation, and realtime concepts.
- Existing conversations migrate naturally as unassigned.
- The nullable reference can later support transfer or automation without
  changing the meaning of the base field.

### Trade-offs

- No assignment history is retained.
- No queue, workload, availability, or routing data exists.
- The current assignee alone cannot express multiple participants or watchers.
- Advanced assignment will require separate operations and possibly additional
  tables rather than expanding this Story implicitly.

## Explicitly deferred

- Transfer to another human agent
- Takeover of another agent's conversation
- Composer locking or message-send authorization based on assignment
- Resolve, close, or reopen lifecycle
- Assignment history and audit reporting
- Named queues and queue membership
- Queue counts and workload dashboards
- Agent presence or availability
- Automatic, round-robin, or load-balanced routing
- Priority, SLA, escalation, and business-hours behavior
- Flow-driven assignment and AI-agent assignment

## Implementation sequence after approval

1. SCRUM-8 adds the nullable relationship, tenant invariant, delete behavior,
   index, generated migration, and generated types.
2. SCRUM-9 adds the two guarded assignment transitions.
3. SCRUM-10 and SCRUM-11 add the views, assignee display, and actions.
4. SCRUM-12 verifies reuse of the existing realtime state flow.
5. SCRUM-13 adds focused tests, regression checks, and documentation.

No schema, API, or UI implementation is part of this ADR.
