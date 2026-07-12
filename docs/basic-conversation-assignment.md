# Basic conversation assignment

OpenBSP currently supports a small assignment foundation for human inbox
ownership. This document describes only the delivered base behavior.

## Data model

Each conversation has one optional assignee:

- `public.conversations.assigned_agent_id = null` means the conversation is
  unassigned.
- A non-null value points to the current human agent assigned to the
  conversation.
- The assignee must be a human agent in the same organization as the
  conversation.
- AI agents, pending invitations without a user, and agents from another
  organization are not valid assignees.

Deleting the assigned human agent clears only `assigned_agent_id`; the
conversation and its messages remain.

## Supported operations

The base workflow has two guarded RPC operations:

1. `assign_conversation_to_me(p_conversation_id)` assigns an unassigned
   conversation to the authenticated user's human agent for that organization.
2. `unassign_conversation_from_me(p_conversation_id)` clears the assignee when
   the authenticated user is the current assignee.

These operations intentionally do not transfer conversations to another agent,
take over another agent's conversation, assign AI agents, or lock the message
composer.

## UI behavior

The UI derives assignment views directly from `assigned_agent_id`:

- **Mine** shows conversations assigned to the signed-in human agent.
- **Unassigned** shows conversations where `assigned_agent_id` is `null`.
- The conversation header shows the current assignee name when the assigned
  agent is loaded.
- The action menu shows **Assign to me** for unassigned conversations.
- The action menu shows **Unassign** only for conversations assigned to the
  signed-in human agent.

Assignment does not change unread state, 24-hour service-window behavior,
archiving, pinning, drafts, or message sending.

## Realtime behavior

Assignment changes update the existing `public.conversations` row. The UI uses
the existing Supabase realtime subscription and conversation store path, so the
Mine and Unassigned views are re-evaluated from the updated row. No
assignment-specific event bus, queue counter, presence channel, routing layer,
or socket layer exists in this base implementation.

## Out of scope

The following advanced assignment features are intentionally deferred:

- Transfer to another human agent
- Takeover of another agent's conversation
- Composer locking or send authorization based on assignment
- Assignment history and audit reporting
- Named queues, queue membership, queue counts, and workload dashboards
- Agent presence or availability
- Automatic, round-robin, or load-balanced routing
- Priority, SLA, escalation, and business-hours behavior
- Flow-driven assignment and AI-agent assignment

## Regression checks

Backend assignment behavior is covered by the Supabase db test:

```bash
npx supabase test db --local supabase/tests/conversation_assignment.sql
```

UI assignment behavior is covered in the UI repo:

```bash
npm test
```
