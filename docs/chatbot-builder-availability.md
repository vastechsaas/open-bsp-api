# Organization-level Chatbot Builder availability (SCRUM-131)

Super Admin can enable or disable Chatbot Builder in an organization's existing
Module permissions screen. This is an access switch, not a runtime stop switch.
Disabling preserves role selections, flow data and the selected activation.
Active bots and accepted background operations continue. Conversation takeover,
resolution and return-to-chatbot permissions are separate and unchanged.

## Database contract

- `organization_module_settings.enabled` defaults to `true`; absent rows also
  retain availability. Only `chatbot_builder` is supported.
- `get_platform_module_permissions` returns `enabled`, `revision` and the stored
  role matrix, even when access is off.
- `update_platform_module_permissions` accepts optional `p_enabled` alongside
  the existing complete matrix, expected revision and stable request ID. Missing
  or null availability preserves the current setting for older clients.
- A retry uses the identical request ID and inputs. Changed inputs require a new
  ID; stale revisions conflict. Audit and private refresh events reuse the
  existing module-permission mechanism.
- Effective permissions are masked when disabled. Existing management guards,
  list RPCs and RLS use the same helper; API-key roles cannot bypass it.

## Rollout and checks

Apply the generated migration before deploying the dependent UI. No function,
Node, Oracle or queue-worker code deployment is required for this slice. Back up
staging and confirm `acifbsuxmpdtlhbsvhlj` before migration deployment. Main
rollout needs separate approval.

Run `supabase/tests/chatbot_availability.sql` and `module_permissions.sql` for
focused database checks, followed by full backend/frontend validation. On an
isolated staging organization, save the original matrix, disable access, verify
tenant listing/editor/management requests are blocked, then re-enable and
confirm the original grants and flow state remain. Also test a second tenant and
live revocation during editing. Do not use the switch to stop active chatbot
replies.
