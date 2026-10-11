# Field-specific chatbot diagnostics

Validation, simulation and publication use the same compiler. Invalid node
configuration retains its graph identity, so dependent routing and reachability
errors remain suppressed. Genuinely absent graph nodes still produce errors.

Configuration issues retain `code`, `path`, `node_id`, `edge_id`, `field` and
`category`. Optional `field_path` is relative to the node configuration.
Optional `params` contains only numeric `option`, `limit` and `actual` values;
request contents and credentials are never returned. Distinct field paths are
not deduplicated together.

The UI translates the code, interpolates numeric parameters, groups by node, and
navigates to the exact nested field. Older responses remain supported. After an
edit, revalidate before displaying server-side inline diagnostics or focusing an
indexed field. Local character counters remain available.

WhatsApp limits remain unchanged: button titles 20 characters, regular list row
titles 24. Switching display mode never truncates saved titles.

## Staging verification

Use an isolated fixture in a test flow; do not edit or activate DKR:

1. A button-rendered list with titles of 21 and 22 characters must show two
   separate errors, including each option number and its 20-character limit.
2. Each issue must open its exact title input, not merely the sections panel.
3. Empty options must show a required-options error. Nonempty options with bad
   titles/IDs or duplicate values must show their actual configuration problem.
4. Switch between regular list and buttons; retain the text and update counters.
5. Edit/remove/reorder an option after validation. Old indexed diagnostics must
   not focus another option; validate again to refresh them.
6. Compare validation and simulation errors. Publishing uses the same compiler
   and must refuse an invalid saved draft.

No database migration, generated type change or standalone Node deployment is
required.

## Main promotion — 2026-10-12

Main promotion was explicitly approved. Port only backend commit `469751c` and
UI commit `fa9dc5a` onto current Main; do not merge unrelated staging changes.
Preserve Main's newer shared support-message wording and placeholders when
resolving the UI conflicts.

The backend full validation passed, including 1,083 local database assertions.
The focused compiler/diagnostics suite passed all 31 tests, including the two
DKR option-length errors and matching simulation diagnostics. The frontend
focused suite passed all 48 tests. The wider chatbot suite exposed two existing
external-reference test expectations missing `field` and `category`; update the
expectations only, retaining the existing external checks. All 129 chatbot and
management tests then passed. Complete frontend validation and deployment checks
are recorded with the release results.

This promotion changes diagnostics and builder guidance only. DKR draft data,
published versions, activation and the Oracle runtime remain untouched. Limits
remain 20 characters for buttons and 24 for ordinary list rows.
