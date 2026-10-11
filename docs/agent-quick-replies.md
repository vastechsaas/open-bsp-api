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

No conversation-history permissions change accompanies this feature.
`list_previous_conversations_page` runs as the caller, with existing database
row access rules, and restricts results to the same organization, customer,
business number and service as the accessible current conversation.

Agents can see active conversations assigned to themselves, or unassigned active
conversations with no queue or a queue they belong to. Closed/spam conversations
require assignment to that agent. An explicit message mention also grants
conversation visibility. Another agent's assignment does not grant access merely
because the customer is the same or the queue is shared.

Previous-chat history is read-only, paginated and access-checked again before
each message page. Owners/admins/supervisors retain their existing wider
organization-level visibility. The panel does not bypass these rules or expose
all conversations belonging to the customer.
