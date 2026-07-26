# TODO

## Before Product Hunt Launch

- [x] Usage, tiers, limits, etc.

## Billing

Core billing (near-term)

- [ ] Renewal cron job — at period end, call change_plan to re-grant balance
      products, rotate current_period_start/end
- [ ] WhatsApp template billing — record template send costs in the ledger
      (costs table is ready, just needs the ledger insert in the dispatcher)
- [ ] Plan downgrade scheduling — store pending plan change, apply at period end
      instead of immediately

Monetization (medium-term)

- [ ] Invoice generation — aggregate usage + overages from plans_products,
      create invoice + items
- [ ] Payment integration — Stripe checkout for paid plans, webhooks for payment
      success/failure/refunds

## Chatbot Builder V1

Epic: SCRUM-67

Current backend work

- [x] SCRUM-68 - Add chatbot builder management API
  - Branch: `scrum-68-chatbot-management-api`
  - Status: first backend version merged into `meta_vista_backend`
- [x] SCRUM-69 - Add paginated chatbot flow listing API
  - Branch: `scrum-69-chatbot-flow-list-api`
  - Status: first backend version merged into `meta_vista_backend`

Planned builder work

- [x] SCRUM-70 - Add Chatbot Builder navigation and flow listing UI
  - Frontend branch: `scrum-70-chatbot-flow-listing-ui`
  - Status: first frontend version merged into `meta_vista_frontend`
- [ ] Build the React Flow editor canvas
- [ ] Implement Start, Send Message, and End nodes
- [ ] Implement Collect Input, Condition, and conditional edges
- [ ] Add draft saving and unsaved-change protection
- [ ] Add validation, publishing, and version viewing
- [ ] Complete builder UX and end-to-end coverage

Deferred beyond V1

- [ ] Flow deployment or activation
- [ ] Side-effect-free simulator
- [ ] Button and list message nodes
- [ ] Webhook/API nodes
- [ ] Loops and subflows
- [ ] Agent assignment and AI processing

## General

- [ ] Improve routing of organization accounts and members

- [ ] Data export / DB dump

- [ ] Langfuse integration

- [ ] Encrypt API keys

- [ ] Improved error handling
      https://modelcontextprotocol.io/specification/2025-03-26/server/tools#error-handling

- [x] Timestamp precision (JS milliseconds vs PostgreSQL microseconds)

- [x] API keys equal agents (same roles and policies)

- [x] Split supabase.ts into different files

- [x] Revisit contacts and contacts_addresses

- [ ] Respond to all / non-contacts

- [ ] Enhanced privacy (optional, do not store messages from contacts)

- [ ] Coexistence welcome message pauses the conversation

- [x] Revisit whatsapp-management security

- [x] Sanitize tool names Error: 400 Invalid 'tools[0].function.name': string
      does not match pattern. Expected a string that matches the pattern
      '^[a-zA-Z0-9_-]+$'.
