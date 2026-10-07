# Chatbot Builder permissions (SCRUM-126)

The module matrix is per organization. Only an authenticated platform
administrator can read or save it from the Super Admin organization detail
screen. Configuring a matrix does not grant tenant-builder access.

## Defaults and persistence

Absent configuration resolves to these defaults for existing and future
organizations:

| Role       | View | Manage |
| ---------- | ---- | ------ |
| Owner      | Yes  | Yes    |
| Admin      | Yes  | Yes    |
| Supervisor | Yes  | No     |
| Member     | Yes  | No     |
| Agent      | No   | No     |

The organization_module_settings table holds the revision. The
organization_module_permissions table holds the five role rows for
chatbot_builder. Save is atomic, requires a stable request UUID and expected
revision, and writes an existing platform audit event. Retrying an identical
request returns its original result. A different request with a stale revision
fails with SQLSTATE 40001. Manage requires View in both the database and UI.

## Enforcement and UI

- has_module_permission uses accepted membership, active organization checks,
  and the API key's stored role. Browser-supplied roles are not used.
- get_effective_module_permissions supplies the current user's capabilities. The
  management endpoint, flow-list RPC and builder RLS enforce permissions.
- View allows listing, version inspection, activation status, validation and
  sample-only simulation. It does not allow graph or credential mutations.
- Manage allows existing management operations; published-version immutability
  and validation remain enforced.
- Credential inspection returns metadata; secret resolution stays service-only.
  Builder option lookup returns only tenant-scoped queue/accepted-agent labels.
- The existing editor is reused, with mutation controls hidden/disabled.
  Realtime signals trigger an authoritative permission re-fetch. Caches are
  scoped to user/organization and cleared on access loss/switch.
- Conversation takeover, close and return-to-bot authorization is unchanged.
  Permission changes do not stop active bot execution.

## Staging acceptance checklist

Deploy the backend migration and management endpoint before the UI. Confirm the
staging project reference before any migration command. Do not merge Main as
part of this rollout.

Using an isolated organization and accepted test accounts:

1. Check all five default role rows, including Supervisor read-only access.
2. Verify View-only canvas selection, pan/zoom, version inspection, Validate and
   mocked Simulate; attempt direct writes and management HTTP requests.
3. Revoke Owner/Admin access and explicitly grant Agent View/Manage. Check
   direct URLs, REST policies, API-key roles and another organization's data.
4. Verify checkbox dependencies, explicit save, identical request retry,
   concurrent-save conflict and old/new audit matrices.
5. Revoke Manage during unsaved editing, then View. Check write suppression,
   warnings, cache cleanup, switching accounts/organizations and reconnect.
6. Verify protected credential values are inaccessible, sample simulation makes
   no live calls, and active chatbots/conversation controls are unchanged.

No Node, Oracle or queue-worker deployment is required.
