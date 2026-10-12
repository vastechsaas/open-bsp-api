# Messages workspace refinement

Staging-first release. Main, Node execution, chatbot flows and conversation
permissions are unchanged.

## Counts contract

`get_conversation_queue_counts(p_organization_id, p_routing_queue_id default null)`
returns `{ key: string, count: bigint }[]` for the current user's enabled views,
including successful zero totals. It is security-invoker, requires an
authenticated organization member and validates routing-queue access. Existing
conversation RLS and support-inbox eligibility apply before aggregation. Names
and order remain in `get_conversation_queues`; no new statuses are introduced.

Predicates match `get_conversation_queue_conversations`, including assignment,
Mentioned's routing-filter exemption and Expired's latest incoming timestamp.
Views overlap, so their totals must not be added into a unique-chat total.
Counts are not based on previews, pagination or search text.

## UI and lifecycle

The UI queries counts with user/organization/routing-queue cache boundaries,
cancellation, Realtime invalidation and visible-page 30-second polling. Errors
display unavailable totals and Retry, not zeros. The ownership banner uses the
same confirmed lifecycle query as the existing header/composer. It changes no
sending permissions, support transitions or lifecycle operations.

Both sidebars, role-specific status names, pinned ordering, Mentioned ordering,
message pagination and organization bubble themes are preserved. Queue selection
moves into Filters. No sorting control or Live indicator is introduced.

## Migration and validation

The migration was generated from schema sources using `npm run db:diff`.
`schema_paths` is now explicitly configured so diff generation does not treat
the schema as empty. The generated migration was scoped to the new RPC,
excluding pre-existing Business Hours/lifecycle function drift and known
Supabase revoke noise. Explicit function grants retain the schema source's
authenticated-only contract. No unrelated function replacements or table/RLS
changes are deployed.

Local validation: 14 new pgTAP assertions; full backend validation passed with
51 files / 1,097 database assertions, Edge Function/plugin lint and type checks,
and voice-service tests/build. Generated types include billing/public/storage
and are synchronized with the paired frontend feature branch.

## Staging release checklist

1. Confirm linked ref `acifbsuxmpdtlhbsvhlj`, never Main `buvjopvpkgvzhykwsxnk`.
2. Save schema and data backups outside Git; confirm the dry run includes only
   `20261012185117_messages_status_counters.sql`.
3. Push/merge backend `codex/messages-status-counters` into
   `meta_vista_backend`, apply its migration, and verify the RPC exists.
4. Only then push/merge UI `codex/messages-workspace-refinement` into
   `meta_vista_frontend` and use its configured preview deployment.
5. Review owner/supervisor/agent status names and totals, queue filtering,
   errors, theme/viewport layouts, history scrolling and confirmed/pending
   ownership. Do not take over or close real customer conversations during
   visual review.
6. Main rollout requires separate approval.

Rollback the frontend to its previous staging revision. The additive RPC can
remain without affecting older UI releases. No data restoration is required.
