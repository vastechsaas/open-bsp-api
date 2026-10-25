# WhatsApp account synchronization — SCRUM-128

OpenBSP is authoritative for a mapped WhatsApp account's connection and
credential. This is separate from flow activation, organization suspension and
human ownership.

## Contract and safety

- Changes to account status, token, verified expiry or WABA reference enqueue a
  revisioned `account-sync` operation. Rows contain references/revisions only.
- The bridge worker resolves the current credential service-side, verifies it
  with Meta, and transfers it over HTTPS with the existing tenant credential.
- Node's `PUT /api/v1/bridge/operations/:requestId` accepts `account-sync`,
  organization/number/WABA IDs, string account revision, connected flag,
  nullable access token and nullable verified expiry. Only a hash and safe
  result persist in its request log; the WABA credential is encrypted
  separately.
- Request status uses the existing operation GET. `GET /api/v1/bridge/account`
  returns revision, connectivity, safe failure code and expiry, never secrets.
- Disconnect waits on the existing company/contact locks, cancels pending bot
  work, clears sessions and invalidates historical menus. Sending/unknown/failed
  dispatches are never blindly replayed. History and human ownership survive.
- Account synchronization never changes `botEnabled`, selected flow/version,
  archive suspension or ownership. Thus reconnect restores only previously
  enabled automation; a previously disabled bot remains disabled.
- Inbound events remain stored/forwarded while the account processing gate is
  suspended. Actual Meta registration/deregistration behaviour is unchanged.
- Profile refresh patches metadata only: it cannot reconnect or overwrite a
  concurrently replaced token. A confirmed current token failure is propagated
  back from Node using revision-checked reconciliation; transient failures do
  not disconnect an account.

## UI and privileges

The existing WhatsApp detail page shows pending/synchronized/failed states.
`whatsapp_account_sync_status` requires accepted active-organization membership
with the existing integration read roles. `retry_whatsapp_account_sync` remains
Owner-only. Credential resolution and completion RPCs are service-only. Queries
are scoped to user, organization and number and cancel stale requests.
Polling/focus/reconnect fetch authoritative status; no token enters a new UI or
operation payload. A mapped disconnect stays on the page until status is clear.

## Deployment order

1. Back up staging `acifbsuxmpdtlhbsvhlj` and the isolated Node database. Never
   link/push against Main `buvjopvpkgvzhykwsxnk` for this rollout.
2. Apply the additive Node migration and deploy API/worker from the Node feature
   branch to a separate staging stack. `compose.staging.yaml` uses independent
   volumes/network and loopback API port 4081, not live DKR's port 4080.
3. Apply generated backend migrations and deploy `node-chatbot-bridge-worker`
   and `whatsapp-management`. The first local migration was followed by a
   generated function-only correction so account jobs cannot block existing Take
   over/Resolve & close; no previously applied migration was rewritten.
4. Keep `NODE_WHATSAPP_ACCOUNT_SYNC_ENABLED` absent/false until the staging
   connection map points exclusively at the isolated runtime for the test
   number. Preserve other connection entries and the existing bridge enabled
   setting. `NODE_WHATSAPP_ACCOUNT_SYNC_CONNECTIONS` permits additive
   isolated-test connections without replacing the existing secret map; existing
   routes win.
5. Enable account sync only in staging, verify the disposable mapping, then
   deploy the dependent UI to `meta_vista_frontend`. Node Main is not merged and
   the live DKR API/worker/configuration are not replaced.

Missing acknowledgments remain visibly pending. An unreachable Node cannot be
promised to stop immediately; retries reconcile stable request IDs. Disabling
the feature flag alone is not rollback of already applied account gates: first
reconcile the test mapping and retain its safe suspended state, then restore the
prior isolated image if necessary. Never restore native processing as a
fallback. Keep the additive schema on rollback.

## Approved Main promotion

After staging approval, promote only SCRUM-128 commits onto the latest Main
branches. Do not merge unrelated staging features or replace Main-only changes.
Back up Main's public/billing schema and data and the production Node database;
retain the previous Node image and Compose configuration.

Keep `NODE_WHATSAPP_ACCOUNT_SYNC_ENABLED=false` in Main until its generated
migrations and compatible backend/API/worker deployments are confirmed. Deploy
the Node migration before replacing API/worker. Verify health and authenticated
account-sync capability before enabling the worker. Keep existing tenant
credentials, connection-map entries, Meta subscriptions and queue configuration.

Enabling reconciliation honors the current account status, including an
intentional disconnection. It does not reconnect an account, reactivate its
selected chatbot or change its engine selection. Verify the latest source and
acknowledged revisions match before reporting synchronization complete.

Scheduled expiry alerts, automatic Meta token generation and a new token
settings screen are outside this slice. The integration queue worker contract is
unchanged.
