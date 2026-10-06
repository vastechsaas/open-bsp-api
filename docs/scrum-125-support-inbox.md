# SCRUM-125: Support-only Node inbox

This feature changes inbox presentation, not authorization or message retention.
Messages and chatbot replies continue to be stored. Authorized direct history
access and the existing paginated history query are unchanged.

## Eligibility

`public.is_support_inbox_visible` is the common server-side predicate. A number
without a Node bridge, or with `engine = native`, keeps its existing behavior.
For Node-managed numbers, a conversation must have an accessible mapping with:

- A waiting support request, human ownership, or a pending lifecycle operation;
- Or resolved support history in Closed (including the existing Spam view).

No mapping means bot-only and hidden. Assignment, routing queue membership,
reading and private-note mentions do not independently establish eligibility.
Fresh bot restart and confirmed release hide the conversation again; they do not
delete its history. Every conversation-access role uses the same rule.

`get_support_inbox_visibility(organization, conversation_ids)` checks
authenticated organization access and existing conversation RLS, accepts at most
500 IDs, and returns only IDs and visibility. Inaccessible IDs are omitted.
Queue and Mentioned RPCs apply the same predicate before ordering, counting and
pagination.

## Client reconciliation

The frontend batches eligibility separately from the message store. Unknown IDs
are not rendered until checked; previously confirmed rows remain stable when a
new batch loads. Responses missing a previously accessible ID revoke its cached
eligibility. Cache scope includes organization and signed-in user.

Mapping and number-binding triggers send `conversation_inbox_changed` through
the existing private organization queue channel. Payloads contain identifiers
only. Clients cancel stale queries and refetch authoritative eligibility,
hydrate previews for revealed conversations, and reconcile again on reconnect.
They do not infer ownership from broadcast delivery order. Eligibility failures
have a translated error and Retry action.

## Deployment and staging verification

Apply the generated migration before deploying its dependent UI. Regenerate and
sync types from the locally applied schema. No Node API/worker, Oracle, queue
worker, flow definition or production webhook update is needed.

The backend staging branch is `meta_vista_backend`; confirm its Supabase Preview
check targets `acifbsuxmpdtlhbsvhlj` before delivery. Frontend staging is
`meta_vista_frontend`. Main rollout is a separate approval.

Verify with an isolated staging Node tenant/number:

1. Send ordinary bot messages: no Messages row, search result or inbox unread
   badge; the stored conversation and message rows still exist.
2. Assign or mention that bot-only chat: it remains hidden.
3. Request support: the permitted queue members see the existing preview and can
   open its earlier paginated history while the bot remains active.
4. Take over: visibility persists and normal ownership restrictions apply.
5. Return to chatbot: after confirmation it disappears without losing history.
6. Escalate again, take over and resolve: Closed retains the support history.
7. Send another message: the fresh bot journey is hidden until escalation.
8. Repeat with accepted Agent, Member, Supervisor, Admin, Owner and authorized
   platform-admin access; verify queue access and organization isolation.
9. Test reconnect, delayed/duplicate events, failed eligibility fetch with
   Retry, and account/organization switching without stale rows or unknown-row
   flashes.
10. Confirm native/PHP and unbridged passthrough conversations remain unchanged.

Database regression: `npm run db:test -- supabase/tests/support_inbox.sql`.
Frontend regression: `node --import tsx --test tests/support-inbox.test.ts`.

Rollback the UI first if necessary. The additive predicate/RPC/notification
changes can remain installed; old frontend versions do not use the batch RPC.
Queue/Mentioned server filtering remains until deliberately reverted through a
new generated migration. Never roll back by deleting conversation history.
