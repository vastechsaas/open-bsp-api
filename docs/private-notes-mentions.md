# Private notes and mentions

SCRUM-96 adds text-only internal collaboration to Chat Center without changing
customer-message delivery or assignment ownership.

## Delivered behavior

- Every accepted human role can create a private note in an active conversation
  it can access.
- Private notes use `messages.direction = 'internal'` and
  `content.kind = 'private_note'`. Their content contains the note text and the
  distinct selected human agent IDs.
- Notes are never sent to Meta, Agent processing, or existing organization
  message webhooks. They do not replace the ordinary incoming/outgoing preview
  or affect main-queue ordering.
- Mention candidates are accepted, non-AI humans in the current organization.
  Availability is not considered. The author, pending/rejected invitations, and
  AI agents are excluded.
- A note can mention multiple people. Mention records are stored in
  `message_mentions` and are tenant-bound to both the source message and the
  mentioned human.
- A stored mention grants an Agent read and private-note access to that
  conversation. It does not grant permission to send a customer reply; that
  remains restricted to the assigned Agent.
- The Mentioned queue comes from `list_mentioned_conversations_page`, not local
  unread or message-cache inference. It is sorted by latest mention time, uses
  the latest non-private message as its preview, and has no unread/count badge.
- Closed and spam conversations remain in Mentioned as read-only history. New
  private notes are accepted only while the conversation status is `active`.

## Write and read paths

Clients create notes only through:

```sql
create_private_note(
  p_conversation_id uuid,
  p_text text,
  p_mentioned_agent_ids uuid[]
)
```

The function derives the author and organization from the authenticated human,
validates conversation access and status, validates all mention recipients,
inserts the message, and then inserts the normalized mention rows in one
transaction. Direct authenticated inserts of private-note messages are blocked.

The UI loads mention candidates through `list_mentionable_humans_page` and loads
Mentioned through the paginated `list_mentioned_conversations_page` contract.
Opening a Mentioned result hydrates its latest 100 messages when the
private-note history is not already in the local store. A realtime private note
mentioning the signed-in human invalidates and refetches Mentioned results.

## Two-agent example

1. Ali owns an active customer conversation.
2. Ali switches the footer from **Reply to customer** to **Private note**, types
   `@Sara Please review the refund request`, selects Sara, and saves the note.
3. The customer and existing external message webhooks receive nothing. The
   conversation remains assigned to Ali and its ordinary preview/order do not
   change.
4. Sara's Mentioned queue refreshes without a page reload. She opens the same
   `/conversations#<id>` route and can read the customer history and yellow
   note.
5. Sara can add a private note, but the customer-reply composer remains disabled
   because Ali is still assigned.
6. If Ali closes the conversation, Sara continues to see it in Mentioned as
   read-only history.

## Deferred work

SCRUM-96 intentionally does not add notification APIs, a notification bell,
unread mention state, a Mentioned count, attachments, note editing/deletion,
presence, teams, or broader customer-reply permissions. A future opt-in
private-note webhook can be designed separately; existing organization webhooks
remain private-note-free.

## Delivery artifacts

- Migration:
  `supabase/migrations/20260806183340_scrum_96_private_notes_mentions.sql`
- Backend feature branch: `scrum-96-private-notes-mentions-backend`
- Frontend feature branch: `scrum-96-private-notes-mentions-ui`
- Backend focused coverage: `supabase/tests/private_notes_mentions.sql`
- Frontend focused coverage: `tests/private-notes.test.ts` and
  `tests/mentioned-queue.test.ts`

Before applying the migration outside local development, confirm the target is
the staging Supabase project, review `supabase db push --dry-run`, and only then
run the push.
