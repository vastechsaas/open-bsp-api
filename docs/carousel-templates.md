# Image carousel templates (SCRUM-132)

Support for catalogue-independent Marketing templates, originally delivered to
staging. The Main rollout was approved on 2026-10-30. The standalone chatbot
engine is unchanged.

## Supported format

- Introduction: up to 1,024 characters, with existing positional variables.
- Two to ten cards. Every card has an IMAGE header, text (up to 160 characters),
  and exactly one HTTPS website button (label up to 25 characters).
- JPEG/PNG files up to 5 MiB each. The file contents must match its MIME type.
- A dynamic URL has one `{{1}}` at the end and a complete sample URL.
- Approved carousel definitions are read-only. Duplicate as draft and submit a
  new template to make changes. Other imported carousel variants cannot send.

## Durable media

`message_templates.components` contains the canonical Meta definition.
`media_assets` is a separate ordered array of stable card IDs and private
`internal://media/organizations/<org>/attachments/<hash>` references. An empty
draft slot contains only `card_id`; it never borrows another card's image.

POST `whatsapp-management/carousel-media` accepts one multipart file,
organization ID, resource (`template` or `campaign`), existing draft ID and card
ID. Existing role checks, storage authorization and quotas apply. It returns an
asset reference and a temporary preview URL. Save draft accepts optional
`media_assets`; older callers that omit it keep their current references.
Submission requires every card image and obtains fresh resumable Meta handles
from retained bytes.

No removal of a card deletes private storage objects. Shared draft, campaign or
message references therefore remain valid under existing retention rules.

## Campaign sending

`campaigns.carousel_media` freezes ordered references and `card_index` values.
Text mappings use `carousel.<zero-based card>.body.<variable>`; URL suffixes use
`carousel.<card>.button.0.1`. Images are shared by all recipients.

Queueing checks retained files. The campaign worker prepares fresh Meta media
IDs once per campaign batch, then resolves each recipient's variables. It never
trusts a client-supplied Meta media ID. Preparing images does not send a
message. Accepted sends are reconciled without marking them eligible for
automatic retry when the result write fails.

Carousel templates are excluded from the manual picker and dispatcher. Existing
campaign-history ingestion is unchanged: this feature does not add conversations
or insert campaign messages into history. Stored carousel data has a read-only
renderer where it already exists.

## Deployment safety

Use the staging project `acifbsuxmpdtlhbsvhlj`. Back up affected data, deploy
the generated schema and backend functions (including campaign-worker and
whatsapp-dispatcher), then deploy the UI. Verify worker RPC execution grants
after generated DROP/CREATE changes; tenant roles must not claim deliveries.

For this rollout, use staging PSDF for inspection/approval submission only. Do
not start a campaign or send templates to any number without new approval.

## Main release — 2026-10-30

Only SCRUM-132 is promoted: backend source commit `b2d990d` and frontend source
commit `deef86b`. Other staging features are not part of this release.

Main project: `buvjopvpkgvzhykwsxnk`. The migration dry run selected only
`20261027200604_carousel_templates.sql`. Before deployment, the affected tables,
function definitions, trigger definitions and migration history were backed up
under the current Windows user's DPAPI protection, outside Git:

`C:/Users/Hurera Mujeeb/.codex/backups/carousel-main-2026-10-30/before-carousel-540cd0b9377e43c5bd938d09715055cb.dpapi`

SHA-256: `E7C938551D38A58E7AFCF5CB02568B8109B6A8AED7D371EB2643CF6492DB745A`. The
backup round trip was verified. Both affected tables were empty at capture.

The release requires `whatsapp-management`, `campaign-worker` and
`whatsapp-dispatcher` from the promoted backend before exposing the editor. No
campaign start, template submission to Meta or customer message is authorized by
this deployment.

The migration was applied to Main and read back successfully. Both columns,
service-role campaign-claim access, authenticated-role exclusion and basic asset
validation smoke checks passed. Deployed functions are active:
`whatsapp-management` version 38, `campaign-worker` version 16 and
`whatsapp-dispatcher` version 28.

All 21 focused carousel/template tests passed. Full backend validation passed
with database tests explicitly skipped because local Docker was unavailable; the
live read-only smoke checks above are not a replacement for the full SQL
regression suite.
