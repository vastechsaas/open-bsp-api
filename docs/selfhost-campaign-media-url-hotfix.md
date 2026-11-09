# Self-hosted campaign image URL hotfix

## Scope

Campaign conversation history and quoted campaign previews share
`signCampaignPreviews`. On self-hosted instances its Storage SDK uses an
internal gateway URL. Browser image links must instead use the configured
`SUPABASE_PUBLIC_URL` HTTPS origin. Keep backend requests internal and preserve
the signed path, query token, private bucket, authorization and 15-minute
expiry. Hosted projects without that optional override keep their existing SDK
URLs.

## Oracle deployment - 9 November 2026

- Source branch: `codex/fix-public-campaign-media-urls`; implementation
  `5201aff`. Main and staging branches were not merged as part of this Oracle
  hotfix.
- Only `whatsapp-management/campaign_reply_context.ts` was deployed; no schema,
  environment, frontend, Node chatbot or worker-image changes.
- Previous file retained at
  `/home/ubuntu/wababase/backups/public-campaign-media-20261109T140328Z/`.
- The campaign worker was gracefully drained, zero preparing/submitting jobs
  verified, Edge Functions reloaded, and the same worker resumed healthy.
- Seven focused campaign-preview/history tests passed. Full backend validation
  passed with `--skip-db` (no database changes); includes formatting, Deno
  lint/type checks, voice tests/build and plugin checks.
- Live read-only Storage signing/HEAD verification: all ten distinct carousel
  images for the reported Optica conversation returned HTTP 200 using public
  HTTPS URLs. Signed links/tokens and credentials were not logged. No sends.

## Rollback

Drain the campaign worker before reloading Edge Functions. Restore only the
backed-up module, reload the functions container and resume the same worker.
Never reset campaign deliveries or resend messages to test an image fix.
