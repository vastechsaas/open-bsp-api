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
required. Main rollout is a separate approval.
