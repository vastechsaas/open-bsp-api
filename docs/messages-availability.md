# Messages availability control

The Messages header uses the former organization-title space for an accessible
Available/Away switch. Available is green with its white thumb on the right;
Away is red with the thumb on the left. Labels stay visible in narrow layouts.
The organization selector elsewhere in the application is unchanged.

Accepted Agents and Supervisors can read, change and heartbeat their own
organization-scoped availability through the existing three presence RPCs.
Pending/rejected invitations and unrelated organizations are not authorized.
Owners/admins are not newly enrolled. Existing 30-second heartbeat and
two-minute freshness rules remain unchanged.

This change does not add Supervisors to routing queues or Round Robin selection,
change business-hours eligibility calculations, change takeover permissions or
automatically assign conversations. Supervisor availability records personal
presence; existing agent-only automated assignment rules remain in place.

Deploy the generated `20261011184531_supervisor_assignment_presence.sql`
migration before the UI. It only replaces function bodies; RPC arguments, return
types, grants and database records are unchanged. The known unrelated
table-grant revokes emitted by the schema diff were removed before local apply.
No Node/PHP/integration-worker deployment is needed.

The switch retains the last confirmed state during a save, disables repeated
clicks, and shows a Retry action on a request failure. An initial loading/error
state is not presented as a confirmed Away status. All new copy is translated
into the application's existing supported locales.
