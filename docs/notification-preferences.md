# Organization notification preferences

Owners configure **Settings → Preferences → Notification Type**. Each toggle
controls one existing in-app bell notification type for the entire organization:
conversation assignment (manual and automatic), agent transfer, queue transfer,
and private-note mentions. These preferences do not configure email, desktop
push, sounds, or customer-facing messages.

All four types default to enabled. No tenant backfill is needed: missing rows in
`organization_notification_preferences` mean enabled for existing and newly
created organizations. Disabling a type suppresses future notification inserts
through `enqueue_user_notification`; it does not remove historical
notifications, mark them read, or change assignment, routing, private notes,
mentions, chatbot ownership, or business-hours enforcement. Re-enabling does not
replay suppressed events. Operations already in flight may use their
transaction's prior settings.

Only an authenticated, accepted Owner of an active organization can read or
change its preferences using the protected RPCs. Direct REST access is revoked.
Changes record the updating user and time. Each save updates only one
notification type, so independent toggles cannot overwrite one another.

Deploy the backend migration before the UI. Staging business-hours rules remain
unchanged; this feature does not deploy Node, Oracle, or the integration worker.
Main rollout remains a separate approval. Rollback can hide the Preferences page
and re-enable the four types; historical notification data is never deleted.
