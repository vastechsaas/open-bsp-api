# Standardized API response formatting

The existing API Call (`webhook`) node owns method, HTTPS URL, request headers,
body template, protected credentials, timeout, retries and success/error routes.
An optional formatter belongs to a **response mapping**, not a particular API.
The formatted scalar is stored in the mapping's output variable. A following
Message node displays it using the normal `{{items_text}}` syntax.

## Builder usage

1. Add an API Call and configure its request and protected credential.
2. Add a response mapping; select its response path and output variable.
3. Choose **Plain value** for existing scalar mappings, or **Formatted list**
   for arrays of records or simple values.
4. Define an item template, separators, empty-list text and item limit.
5. Paste non-sensitive sample JSON into the local preview. It is not saved and
   does not call the endpoint. Simulation also uses mocked responses.
6. Connect both API success and error routes. Validate, publish and reactivate
   only after a real endpoint test succeeds with the required credentials.

Paths use `data.items`, `items.0.name`, or `$` for the root response. Templates
support `{{item.name}}`, `{{item.details.price}}`, `{{response.currency}}`,
`{{index}}` (one-based), and `{{item}}` for arrays of plain values. Arrays of
scalars such as `{{item.features}}` use the configured value separator. Objects,
missing/null fields and nested arrays cannot be rendered as text. Use only
fields guaranteed by the provider; prices are never inferred.

Example configuration (the names are configuration, not runtime API logic):

```json
{
  "path": "plans",
  "variable": "plans_text",
  "format": {
    "kind": "list",
    "item_template": "{{index}}. {{item.name}}\nPrice: {{item.price}}\nDuration: {{item.duration_days}}\nFeatures: {{item.features}}\nPayment methods: {{item.payment_methods}}",
    "separator": "\n\n",
    "array_separator": ", ",
    "empty_text": "No plans are currently available.",
    "max_items": 20
  }
}
```

For DKR staging, the documented request is POST
`https://staging.dilkarishta.com/api/whatsapp/plans` with a customer's E.164
`phone_number`, JSON content type and protected `X-Api-Key`. DKR must whitelist
the Node server's outbound IP; Node must allow the API domain. No real API key,
customer data, live flow edits or activation is included in this feature.

## Contract and safety

- Existing mappings without `format` keep their behavior.
- No JavaScript, expressions, arbitrary filters, HTML, session variables or
  secret access in response templates. Only the selected response is visible.
- Limits: 50 items, 2,000-character item template, 32-character separators,
  500-character nonblank empty text and 4,096-character formatted result.
- Exceeding an item/output limit fails rather than silently dropping plans.
- Formatting/mapping errors follow the API error route; mappings commit
  atomically, with no partial variable updates.
- Formatting does not generate dynamic buttons or purchase/payment actions.
- Array/format settings remain in the existing versioned flow JSON. There is no
  database migration or generated database-type change.

## Shared implementation and rollout

`supabase/functions/_shared/chatbot/response_format.ts` is the canonical,
dependency-free formatter. Mirrors are used by React preview and Node runtime.
Synchronize/check feature worktrees with explicit paths:

```text
node scripts/sync-chatbot-response-format.mjs --ui-file=<UI>/src/utils/ChatbotResponseFormatter.ts --node-file=<NODE>/standalone/src/core/utils/responseFormat.ts
node scripts/sync-chatbot-response-format.mjs --check --ui-file=<UI>/src/utils/ChatbotResponseFormatter.ts --node-file=<NODE>/standalone/src/core/utils/responseFormat.ts
```

After synchronizing, apply the UI's Prettier formatting. `--check` normalizes
formatting before comparing, so style differences do not count as drift.

Deploy Node API/worker support **before** activating formatted flows. Deploy
OpenBSP management/compiler support before the builder UI. Existing published
versions remain unchanged until a new version is published and activated.
Rollback must deactivate formatted versions or reactivate an older compatible
version before rolling back either engine. Do not remove formatter fields and
claim the same behavior is preserved.
