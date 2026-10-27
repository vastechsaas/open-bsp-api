# Image carousel templates (SCRUM-132)

Staging-first support for catalogue-independent Marketing templates. Main and
the standalone chatbot engine are outside this rollout.

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
