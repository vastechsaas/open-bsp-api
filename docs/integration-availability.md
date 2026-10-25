# Organization integration availability (SCRUM-129)

Super Admin → Organization → Integrations controls connection **management**,
not account connectivity or messaging. WhatsApp and Instagram default to enabled
for every existing/new organization. Existing role permissions still apply.

## Storage and interfaces

- `integration_catalogue`: deployment-managed identifiers, labels and defaults.
  New rows default to disabled. Seeded WhatsApp/Instagram rows opt in
  explicitly.
- `organization_integration_settings`: one revision per organization.
- `organization_integration_availability`: organization/provider overrides.
- `get_platform_integration_availability` and
  `update_platform_integration_availability`: Super Admin only. Complete atomic
  saves require the observed revision and a stable UUID. A stale revision
  returns SQLSTATE `40001`; reusing an ID with a different request returns
  `22023`.
- `get_effective_integration_availability`: accepted, active tenant members
  only. The internal boolean helper also supports existing organization API
  keys.
- Saves use the existing platform action audit and a private organization-scoped
  `integration-availability` broadcast. Clients always re-fetch authoritative
  data.

No interface returns credentials. Raw settings/catalogue writes are unavailable
to authenticated/anonymous clients. Availability does not modify account status,
credentials, bridge selection, bot activation, queues or historical access.

## Enforcement boundary

After existing authorization (or validated onboarding token), the authoritative
signup helper checks availability **once, before external registration starts**.
A disable blocks later requests but lets already-accepted registration finish.
The generic Instagram authorize URL helper cannot identify a tenant and does not
grant connection permission; its authoritative callback is guarded.

Onboarding-token INSERT policies also enforce availability. Saved valid links
are not consumed/expired when disabled; GET and POST onboarding reject them
until the integration is enabled again. Existing token-expiry validation remains
unchanged.

Explicit WhatsApp profile updates/sync and Super Admin profile refresh are
guarded. Disconnect/revocation, signed provider deauthorization/deletion,
inbound webhooks, reply dispatch, Instagram token maintenance, campaigns and
operational template usage are intentionally **not** gated.

## UI

The same effective query gates integration cards, setup shortcuts, WhatsApp
Manager and direct management routes. Revocation unmounts management controls
without deleting account data. Template routes remain operational. Query keys
include both organization and user, abort old requests and refresh on
focus/reconnect/broadcast.

## Adding another integration

1. Implement the connector and register a stable catalogue ID in a schema/data
   migration. Leave `default_enabled` false for opt-in availability.
2. Reuse the availability guard after authorization/token resolution, before
   setup/configuration effects. Do not gate operational messaging/maintenance.
3. Add the UI route mapping and management entry-point checks. The Super Admin
   list and save protocol automatically include the new catalogue row.
4. Test both allowed and blocked setup, callbacks, tenant boundaries and
   unchanged operational traffic before enabling the provider for any
   organization.

## Staging and rollback

Deploy backend schema/functions before the UI. Confirm project
`acifbsuxmpdtlhbsvhlj`, retain the protected database backup, run a migration
dry run, and verify only the new migration is pending. Never apply this slice to
Main without subsequent approval. No Node/Oracle/queue-worker deployment is
needed.

Rollback UI/function images together. Availability changes are reversible
through the audited settings RPC; leave the additive tables in place. Turning
management off is not a remote account disconnect and must not be advertised as
one.
