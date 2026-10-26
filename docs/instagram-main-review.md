# Instagram: selective Main rollout for Social Connect

This rollout brings the tested Instagram-specific staging fixes to Main without
merging integration availability, Chatbot Builder availability or other staging
features. Existing schema, generated types, WhatsApp, Node and PHP stay
unchanged.

## Included

- Owner-only, accepted-membership connection management, active-organization
  checks, service/tenant isolation and token-free onboarding responses.
- Separate Instagram login and webhook signing secrets; raw-byte signature
  verification. Diagnostics remain off unless explicitly enabled.
- Outbound dispatch uses the existing internal credential, not a Meta token.
- Revoked-token warnings, safe reconnection and original-user/org OAuth state.
- Instagram integration entry, reconnect/error states and public information.

## Main configuration

- Supabase: `buvjopvpkgvzhykwsxnk`.
- Website: `https://socialconnect.vastech.biz`.
- Redirects: `/oauth/instagram` and `/onboard/instagram/callback` on that
  website.
- Webhook: the Main `instagram-webhook` function, not the Node WhatsApp webhook.
- Deauthorize and deletion callbacks: Main `instagram-management/deauthorize`
  and `instagram-management/data-deletion`.
- Backend settings: `INSTAGRAM_APP_ID`, `INSTAGRAM_APP_SECRET`,
  `INSTAGRAM_VERIFY_TOKEN`, `INSTAGRAM_WEBHOOK_APP_SECRET`, and the existing
  `EDGE_FUNCTIONS_TOKEN`. Do not replace WhatsApp credentials.
- Request only `instagram_business_basic` and
  `instagram_business_manage_messages` for this inbox feature.

Take a private backup before deploying. There is no new database migration.
Deploy only Instagram functions; use the configured frontend Main deployment.
Meta dashboard callback changes and authorization must be completed by an
authorized operator. Never copy a staging account/token into an unrelated Main
organization merely to make a test pass.

## Verification and rollback

Check the real Main site, authorize a dedicated professional Instagram account
inside an isolated review organization, send a real customer DM, confirm it
appears in Chat Center and reply back to Instagram. Check disconnect/reconnect
and invalid-signature rejection. Test webhooks alone do not prove that round
trip. Do not claim App Review readiness until that operator-assisted test
passes.

For rollback, deploy the recorded previous Instagram function revisions and
frontend commit. No schema rollback, Node restart or WhatsApp webhook change is
needed. Preserve connected-account records and any newly stored history.
