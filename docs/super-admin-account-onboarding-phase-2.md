# Super Admin account onboarding — Phase 2

## Scope and release boundary

Staging only: `acifbsuxmpdtlhbsvhlj`. No Main or Node deployment. Team members
retains the Phase 1 pending-membership option and adds direct creation and email
setup. Only Owner, Supervisor and Agent are manageable.

The administrator confirmed SMTP is **not configured**. Real invitation receipt,
cross-device setup and continuation-email tests remain pending until SMTP is
ready. Do not claim end-to-end email delivery or enable delivery before those
checks.

## Server contract and safety

`platform-user-onboarding` checks Auth identity and platform authorization on
every administrator request. Its private service-only SQL command reserves the
membership and capacity before calling Auth. Operations reserve normalized email
across tenants, preallocate the Auth ID, and require matching server-owned Auth
app metadata on reconciliation. Creation never adopts unrelated existing
accounts.

Actions: `create`, `status`, `retry`, `resend`, public secret-context `preview`,
and recipient-JWT `complete`. New and existing pending memberships use the same
ledger. The three UI modes are invitation, direct account and Phase 1 pending
membership.

Passwords are transient HTTPS inputs, never SQL parameters, event/audit
payloads, query-cache variables or application-table values. Direct creation
confirms email and accepts only the selected membership. Auth itself retains its
normal password hash; the application does not copy or fingerprint it.

Supabase Admin creates a random inaccessible password when no password is
supplied. Do not interpret its nonempty encrypted-password column as recipient
completion. Invitation completion writes the chosen password **and** a protected
`onboarding_password_set` app-metadata marker in the same Auth update. Recovery
checks that marker, never resets a completed password, and finalizes only the
selected membership. Other pending invitations linked by existing triggers stay
pending. No Auth account is automatically deleted on failure.

External work uses a 90-second lease and 25-second Auth HTTP timeout.
Cancellation and role changes invalidate setup and are blocked while a lease is
active. Ordinary membership acceptance cannot bypass an unfinished setup, even
with partial JSON updates. Name-only changes remain possible.

Setup contexts are HMAC-derived opaque values with only their SHA-256 hashes
stored. The derivation is domain-separated and includes operation and resend
generation; an ambiguous retry reconstructs the same context without storing a
raw token. Explicit resend rotates the generation and revokes the previous app
context. Application contexts last 24 hours; native Auth link expiry is
independently enforced by Supabase. Neither expiry nor password-policy settings
are weakened.

The dedicated `/onboard/set-password` route verifies `token_hash` explicitly
when the user clicks Verify invitation. It does not use the admin browser's PKCE
state. Isolated sessionStorage supports refresh and does not overwrite another
signed-in account. URL parameters are scrubbed before rendering. A different
signed-in user must use a private window or sign out first. Tenant subscriptions
do not initialize on the setup page.

## Protected staging configuration

Set the following Edge Function secrets using protected configuration:

```text
PLATFORM_ONBOARDING_CALLBACK_URL=https://vistagalaxy.vastech.biz/onboard/set-password
PLATFORM_ONBOARDING_MAIL_ENABLED=false
# Optional dedicated high-entropy stable secret:
PLATFORM_ONBOARDING_CONTEXT_SECRET=<protected random secret>
```

Without a dedicated context secret the existing server-only service-role key is
used with HMAC domain separation. Rotating either effective key requires
resending unfinished invitations. Do not expose these secrets as Vite variables.

Configure company SMTP and sender identity in staging Supabase Auth. Allowlist
the exact staging setup callback (including query parameters using Supabase's
supported redirect matching). Preserve existing redirect entries and Auth
expiry/password policy. Never apply these settings to Main as part of this
release.

Customize **Invite user** and **Magic Link** templates without breaking existing
provisioning/login templates. Branch only for the feature metadata marker:

```html
{{ if eq .Data.account_onboarding "v1" }}
<a href="{{ .RedirectTo }}&token_hash={{ .TokenHash }}&type=invite">Set password &amp; join</a>
{{ else }}
<a href="{{ .ConfirmationURL }}">Accept invitation</a>
{{ end }}
```

Use `type=magiclink` in the Magic Link template's feature branch and preserve
its existing fallback content. RedirectTo already contains operation/context
query parameters. Do not place service keys, passwords or the native token in
logs. The metadata marker only selects the email template; server context/JWT
checks provide authorization. Disable link tracking that rewrites/consumes Auth
links.

After configuration, set `PLATFORM_ONBOARDING_MAIL_ENABLED=true` and use only a
controlled staging inbox. A successful Auth send indicates SMTP acceptance, not
proof of inbox delivery.

## Recovery and operator checks

- After an error, refresh Team members and use **Set up login**, **Check
  status** and **Retry** on that membership. Do not create another membership.
- Direct retries need password re-entry only if Auth creation did not succeed.
  Existing operation-owned Auth accounts are reconciled without a password
  reset.
- Native invitation resends target only unconfirmed operation-owned accounts.
  Confirmed but unfinished recipients receive a one-time continuation via OTP
  with account creation disabled. Completed/unrelated accounts cannot use
  resend.
- Wait at least one minute between new resend attempts. Ambiguous retries keep
  the delivery request ID and context. A busy lease expires automatically; check
  status before retrying. Never resolve ambiguity by deleting an Auth user.
- Review append-only `platform_user_onboarding_events`: administrator and
  recipient events retain actual actor IDs and safe role/member snapshots. No
  secrets.
- Rollback UI first and disable email delivery. Retain schema/ledger and Auth
  users. Do not remove the acceptance guard while unfinished setups exist.

## Required acceptance checks

Focused SQL and Deno tests cover reservation, restricted roles, email collision,
stable retry, acceptance bypass, recipient identity, revocation, capacity,
ambiguous Auth/password outcomes and SMTP failures. UI tests cover modes, safe
errors, isolated per-tab setup and translations. Run full backend/UI validation
before staging merge; record concrete results below.

With controlled inboxes, verify direct login for each role without email, invite
receipt, cross-browser setup, refresh, resend before/after confirmation, expiry,
reused/revoked links, wrong signed-in account, partial Auth/membership recovery,
and that other organizations/credentials remain unchanged. Retain test accounts
unless deletion is separately approved.

## Validation and staging preparation — 22 October 2026

- Generated and applied local migrations `20261021185856` and `20261021190930`;
  generated backend types and synchronized the UI copy. Known unrelated migra
  table-revoke noise was removed before applying either migration.
- Focused onboarding SQL: 37 assertions passed. Deno core tests: 8 passed.
- Full backend validation completed format/lint/type checks, voice tests/build,
  plugin checks and all 53 SQL files (1,188 assertions). Three existing
  broadcast assertions initially failed with local Realtime stopped; after
  restoring it, the affected files plus onboarding passed all 85 assertions on
  rerun.
- Full UI validation: all 425 tests passed, generated types matched, lint had no
  errors, TypeScript and production build passed. Existing lint warnings remain;
  new-file warnings were corrected with focused follow-up checks.
- An additional real-local-Auth smoke script is available at
  `scripts/verify-account-onboarding-local.ts`. Local Kong/Auth returned HTTP
  504 during fixture account creation, so this additional check is **not
  passed**. Any synthetic local Auth accounts created before timeouts are
  retained. No real email was sent. Do not mistake mocked invitation delivery
  for an inbox test.
- Staging schema/data backups are outside Git in
  `C:/Users/Hurera Mujeeb/.codex/backups/staging-account-onboarding-20261021/`.
  Dry run confirmed exactly the two feature migrations, targeting staging.
- Protected staging callback is configured; email delivery is explicitly
  disabled pending company SMTP, template and redirect configuration. Main is
  unchanged.
- Backend commits `e14fb63` / `d03443e` were fast-forwarded to
  `meta_vista_backend`; both migrations and `platform-user-onboarding` were
  explicitly deployed to staging. The rollback-only staging smoke passed private
  RPC/table access, pending reservation, stable retry and role-change
  revocation. The deployed endpoint returns HTTP 401 with a safe code for a
  missing session.
- UI commits `9d2aa4a` / `563eca1` were fast-forwarded to `meta_vista_frontend`.
  Additional guards cover legacy Auth fragments, trailing-slash setup routes and
  an account changing during completion. Focused setup/auth tests passed after
  those guards were added. SMTP delivery and recipient browser tests remain
  pending, not passed.
- Vercel `meta-vista-ui` confirmed staging deployment success for
  `563eca135d5bf7c8996616f58224dfd5168d4bf9`. Browser review on staging verified
  the default invitation mode, direct password/confirmation/acknowledgment
  fields, pending-only mode and existing Administrator read-only presentation.
  No account form was submitted and no credentials were entered or changed
  during this review.
