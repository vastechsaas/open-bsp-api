# WhatsApp attachment recovery

Live inbound WhatsApp files for enabled organizations are committed with a
private recovery job. The worker uses the original phone number's current Meta
credential and an organization-scoped, content-hashed Storage path.

## Staging rollout

1. Confirm the expected staging project. Back up the affected database before
   applying the migration. Deploy the backend functions with
   `WHATSAPP_ATTACHMENT_RECOVERY_ENABLED` absent or false. The migration's cron
   job does not invoke Edge Functions until there is due work.
2. Deploy the compatible Chat Center. Verify a signed inbound fixture and mocked
   Meta success, timeout, and terminal failure. Never send outbound messages as
   part of this check.
3. Set `WHATSAPP_ATTACHMENT_RECOVERY_ORGANIZATIONS` to the comma-separated UUIDs
   of isolated staging organizations before setting
   `WHATSAPP_ATTACHMENT_RECOVERY_ENABLED=true`. An empty allowlist means all
   organizations; do not use an empty allowlist during the canary.
4. Check queue age, state counts and the rate of browser Storage 400s using
   aggregate diagnostics. Do not expose raw media IDs, credentials, signed URLs,
   or attachment content in operational logs. Production rollout is separate.

## Pause or rollback

Unset `WHATSAPP_ATTACHMENT_RECOVERY_ENABLED` to stop new queuing and worker
processing. Retain the migration, Storage files, messages and jobs; re-enabling
resumes eligible jobs. If pausing for an extended incident with a backlog, pause
the `whatsapp-attachment-recovery` cron job so it does not keep waking a
disabled worker. Re-enable the scheduler alongside the Edge flag. The Chat
Center guard can remain deployed independently to avoid useless Storage requests
for raw Meta IDs. Never replay customer messages to recover files.
