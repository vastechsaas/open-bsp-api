# Instagram: selective staging integration

## Compatibility audit

Compared backend staging `439c6cd` and UI staging `563eca1` with upstream
backend `b0b124e` and UI `735e00d`.

| Area                      | Finding / decision                                                                                                                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Existing feature          | Instagram Login, account management, public onboarding, signed webhook, inbound messages/media, outbound sends and daily token refresh already exist. Reuse them.                                                                      |
| Hidden entry              | The UI explicitly commented out the Instagram Integrations card. Restore it; do not enable the unrelated media-preprocessing entry.                                                                                                    |
| Missing upstream fix      | Adapt upstream [c6fa999](https://github.com/matiasbattocchia/open-bsp-api/commit/c6fa999f99f0e04e396ce393b07b3116a70f3ada): flag revoked tokens during dispatch/profile fetching, not only near token expiry.                          |
| Local compatibility fixes | Keep Instagram-only account filters, clear stale reconnect flags after login, bind OAuth return to its initiating user/organization and omit OAuth tokens from signup/onboarding responses. Preserve owner-only connection management. |
| Excluded upstream changes | No new addressing model, contacts deletion, conversation-status removal, role/invitation rewrite, user-scoped account ownership or reaction model replacement. These are platform changes, not Instagram prerequisites.                |
| Database                  | Existing tables, JSON extra, merge-update trigger and token-refresh cron suffice. No migration or generated-type change in this slice.                                                                                                 |

This is not a wholesale upstream merge. WhatsApp/Node/PHP code, numbers, queues,
conversation statuses, takeover and chatbot definitions are unchanged.

## Before staging testing

Read-only staging inspection on 24 October 2026 found all three Instagram
functions ACTIVE (webhook v26, management v65, dispatcher v65), but none of the
three `INSTAGRAM_*` secrets below. Deployed functions alone therefore do not
establish a working connection. No remote configuration was changed.

- Confirm staging project is `acifbsuxmpdtlhbsvhlj`. Do not configure Main.
- Configure the Instagram app's own `INSTAGRAM_APP_ID`, `INSTAGRAM_APP_SECRET`
  and `INSTAGRAM_VERIFY_TOKEN` as backend secrets. Do not reuse/replace
  `META_APP_*` or WhatsApp verification settings.
- Configure `INSTAGRAM_WEBHOOK_APP_SECRET` separately from the hosting Meta
  app's **App settings > Basic**. The webhook uses this for signature checks;
  OAuth keeps using `INSTAGRAM_APP_SECRET`. Existing single-secret deployments
  remain compatible only when the dedicated setting is absent. An explicitly
  empty setting or mismatched multi-app lists rejects ingestion. Signature
  failures never persist a message; HTTP 200 alone is not delivery evidence.
- The optional Release workflow now forwards these three secrets when present;
  GitHub/Supabase automated deployment does not create missing secret values.
- Use one isolated staging organization and an Instagram professional test
  account. Confirm the app/account is allowed to use Instagram messaging in its
  current Meta app mode. App review/permissions must be checked in Meta, not
  inferred from a successful build.
- Register the actual frontend callbacks:
  `https://vistagalaxy.vastech.biz/oauth/instagram` and
  `https://vistagalaxy.vastech.biz/onboard/instagram/callback`. The older
  README's `/onboard-instagram/callback` is not the current UI route.
- Use the separate Instagram webhook:
  `https://acifbsuxmpdtlhbsvhlj.supabase.co/functions/v1/instagram-webhook`.
  Leave the existing WhatsApp webhook and Node routing untouched.
- Compliance endpoints are under
  `/functions/v1/instagram-management/deauthorize` and
  `/functions/v1/instagram-management/data-deletion`.
- Confirm the existing `refresh-instagram-tokens` cron and its Vault
  edge-function URL/service credential are configured on staging.

No secret values belong in this document or frontend build variables.

## Staging checklist

1. Validate the backend feature branch before its dependent UI branch.
2. Deploy backend staging first, then frontend staging. Main needs separate
   approval.
3. Owner connects an account; cancel/deny and retry OAuth too. Switching user or
   organization during login must fail safely, not connect to a different
   tenant.
4. Send a customer DM; verify one stored message, correct tenant, history and
   assignment visibility. Retry the same webhook and check duplicate prevention.
5. Reply with text and supported media. Check accepted/read statuses, captions
   and unsupported payload failures using the existing message model.
6. Revoke the test account's token. Verify the reconnect warning; reconnect and
   verify the warning clears. Do not invalidate a live WhatsApp token.
7. Check an unauthorized/pending member cannot connect/disconnect, and an
   archived organization cannot connect.
8. Regression-test WhatsApp send/receive, DKR, takeover/close, history,
   invitations, organization switching and role restrictions.

Code tests use mocked Meta responses. They do not establish that staging
secrets, Meta permissions, callbacks or real message delivery are configured.

## Validation evidence

- Focused Instagram endpoint tests: 15 steps passed, including revoked tokens,
  inbound persistence, archived organizations, pending membership, API-key
  tenant binding, reconnection and token-free onboarding responses.
- Focused database compatibility tests: 8 assertions passed. Existing JSON merge
  preserves metadata; a late failure cannot flag a newly replaced token.
- Full backend `npm run validate`: passed, including 54 database test files /
  1,196 assertions, Deno lint/type checks, plugin checks and voice-service
  checks.
- Additional full Deno unit run: 194 passed (including the 15 Instagram steps),
  2 failed. Both failures are unchanged chatbot reference-test expectations:
  `agent_references_test.ts` omits the existing `field` / `category` metadata.
  Reproduced both failures on clean staging commit `439c6cd`. No unrelated
  chatbot implementation or test was edited to conceal them.
- UI tests/build results are recorded in the UI feature commit/delivery summary.
- Dependency manifests and lockfiles are unchanged. Existing npm audit findings
  were not addressed through an unrelated dependency upgrade.

### Webhook signing hotfix — 24 October 2026

- Added separate `INSTAGRAM_WEBHOOK_APP_SECRET` selection without changing
  working OAuth credentials or WhatsApp configuration. Signature failures no
  longer log expected/received signature values.
- Focused check: from `supabase/functions`, run
  `deno test --allow-env --allow-net --allow-read _shared/instagram_integration_test.ts`.
  All 21 steps passed, including dedicated-secret precedence, OAuth-key
  rejection, tampered bodies, legacy fallback, empty configuration and multi-app
  isolation.
- Quick and full backend validation passed; the full database suite passed 54
  files / 1,196 assertions. No migration or generated-type change is needed.
- After staging deployment, send a new real DM and check `Persisted messages`
  plus stored conversation/message rows. Previously rejected webhooks were
  acknowledged with HTTP 200 and are not automatically replayed by this fix.

## Remaining boundaries / rollback

- Live Meta configuration and end-to-end verification require the test
  app/account.
- Account tokens remain in the pre-existing backend account JSON store; changing
  direct REST column visibility for all integrations is a separate permission
  audit. This slice removes tokens from Instagram management HTTP responses.
- Public onboarding-token consumption remains the existing implementation; a
  concurrent-use reservation redesign is not imported from unrelated upstream
  work.
- The legacy contact cache is organization/contact-scoped, not
  connection-scoped. Do not assume the newer upstream multi-connection
  address-book model is present.
- If a staging test fails, disconnect the test Instagram account and restore the
  previous application versions. No schema rollback or WhatsApp webhook switch
  is needed for this slice.
