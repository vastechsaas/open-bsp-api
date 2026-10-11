# Agent Quick Replies and previous-chat access

Accepted Agents, Supervisors, Administrators and Owners can create, edit and
delete the organization's shared Quick Replies using the existing authenticated
RPCs. Replies are not personal/private to their creator. Editing or deleting a
shared reply affects the whole organization.

The 50-reply organization cap, shortcut validation/uniqueness, 1,000-character
content limit, tenant isolation and accepted-membership checks remain intact.
Pending invitations and AI identities do not gain management access. Direct
table writes remain blocked; mutations use the existing RPCs. Deploy the
generated function-body migration before the frontend permission update.

Previous chats provides shared, read-only customer history regardless of which
agent handled an earlier chat. `list_previous_conversations_page` and
`list_previous_conversation_messages` validate the caller's accepted membership
and access to the current conversation on every request. They return history
only for that same organization, customer, business number and service.

Ordinary inbox permissions remain unchanged: Agents see their assigned active
chats and eligible unassigned chats, their assigned closed/spam chats, and
explicitly mentioned conversations. The Previous chats panel is the scoped
exception for reading earlier customer history; it does not add other agents'
chats to the inbox or grant takeover, assignment, note-writing or sending
rights.

Lists use bounded server pagination and messages use timestamp plus ID cursors.
Each page rechecks current-conversation access, so membership removal,
reassignment or tenant archival can revoke history access. The internal context
helper is not client-callable. Owners/admins/supervisors retain their existing
wider organization-level visibility. No conversation or message records move.
