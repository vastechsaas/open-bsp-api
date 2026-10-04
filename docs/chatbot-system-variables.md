# Chatbot system variables

`{{customer_phone}}` is the customer's WhatsApp sender identity in international
format, e.g. `+923001234567`. It is available from the first node, in messages,
conditions, acknowledgments and API URL/header/body templates.

Use it in an API body instead of asking the customer to type their number:

```json
{ "phone_number": "{{customer_phone}}" }
```

It is read-only. Inputs, text menus, API response mappings and Node variable
defaults/writes cannot replace it. Runtime execution ignores stored values and
editable contact attributes; it refreshes trusted identity on session
restoration, including delays and historical-menu navigation. Node reuses
branded in-memory context within one execution chain to avoid repeated contact
reads.

The native executor uses the inbound WhatsApp contact address. Node uses its
tenant-scoped contact's transport `waId`, populated by webhook ingestion.
Neither guesses a country code or falls back to a customer-entered/profile phone
number. If trusted identity is unavailable, templates fail normally rather than
sending a request with an invented phone number.

Simulation uses `+923001234567`, without storing or sending a real phone number.
No database migration, flow activation or credential changes are required.
