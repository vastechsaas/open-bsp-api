import { assertEquals } from "../_shared/test_assert.ts";
import {
  campaignReplyPreview,
  campaignReplyRequest,
  readCampaignReplyContext,
  sameCampaignRecipient,
} from "./campaign_reply_context.ts";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/supabase.ts";

const org = "6c805acd-0b8c-4581-bb95-2eec9fdc558d";
const conversation = "ee337b4b-9cec-49c2-afce-f47c937176a0";
const reply = "94061669-752c-45ea-9b2a-00a83e8656e9";
const cardId = "d981307d-1a74-4460-b16c-11ec27627bf3";
const input = {
  organization_id: org,
  conversation_id: conversation,
  reply_ids: [reply],
};
const campaign = {
  id: "campaign",
  organization_address: "111",
  name: "New arrivals",
  template_variable_mapping: {
    "body.1": "contact.name",
    "carousel.0.body.1": "csv.product",
    "carousel.0.button.0.1": "csv.slug",
  },
  template: {
    components: [
      { type: "BODY", text: "Hello {{1}}" },
      {
        type: "CAROUSEL",
        cards: [{
          components: [
            { type: "BODY", text: "See {{1}}" },
            {
              type: "BUTTONS",
              buttons: [{
                type: "URL",
                text: "View",
                url: "https://example.test/products/{{1}}",
              }, { type: "URL", text: "Unsafe", url: "javascript:alert(1)" }],
            },
          ],
        }],
      },
    ],
  },
  carousel_media: [],
};
const delivery = {
  campaign_id: campaign.id,
  external_id: "wamid.Campaign==",
  contact_address: "+923001234567",
  name: "Customer",
  variables: { product: "a watch", slug: "watch" },
};

Deno.test("campaign quote renders personalized snapshot with safe links and scoped media", () => {
  const path = `organizations/${org}/attachments/${"a".repeat(43)}`;
  const asset = {
    card_id: cardId,
    storage_uri: `internal://media/${path}`,
    mime_type: "image/jpeg",
    file_name: "watch.jpg",
    size: 5,
  };
  const preview = campaignReplyPreview(
    { ...campaign, carousel_media: [asset] },
    delivery,
    org,
  );
  assertEquals(preview.body, "Hello Customer");
  assertEquals(preview.cards, [{
    text: "See a watch",
    links: [{ label: "View", url: "https://example.test/products/watch" }],
    imagePath: path,
  }]);
  assertEquals(
    campaignReplyPreview(
      { ...campaign, carousel_media: [asset] },
      delivery,
      cardId,
    )
      .cards[0].imagePath,
    undefined,
  );
});

Deno.test("campaign lookup accepts only a bounded set of internal reply IDs", () => {
  assertEquals(campaignReplyRequest.safeParse(input).success, true);
  assertEquals(
    campaignReplyRequest.safeParse({
      ...input,
      reply_ids: Array(51).fill(reply),
    }).success,
    false,
  );
  assertEquals(
    campaignReplyRequest.safeParse({
      ...input,
      reply_ids: [delivery.external_id],
    }).success,
    false,
  );
  assertEquals(
    sameCampaignRecipient("923001234567", delivery.contact_address),
    true,
  );
  assertEquals(
    sameCampaignRecipient("923001234568", delivery.contact_address),
    false,
  );
});

Deno.test("campaign quote cannot bypass conversation visibility, sender or recipient checks", async () => {
  let allowed = false;
  let address = campaign.organization_address;
  let recipient = "923001234567";
  let serviceRequests = 0;
  const user = createClient<Database>("https://user.example.test", "key", {
    auth: { persistSession: false },
    global: {
      fetch: (request) => {
        const url = new URL(String(request));
        assertEquals(url.searchParams.get("organization_id"), `eq.${org}`);
        return Promise.resolve(Response.json(
          url.pathname.endsWith("/conversations")
            ? allowed ? [{ id: conversation }] : []
            : [{
              id: reply,
              contact_address: recipient,
              organization_address: address,
              content: { kind: "text", re_message_id: delivery.external_id },
            }],
        ));
      },
    },
  });
  const service = createClient<Database>(
    "https://service.example.test",
    "key",
    {
      auth: { persistSession: false },
      global: {
        fetch: (request) => {
          serviceRequests++;
          const url = new URL(String(request));
          assertEquals(url.searchParams.get("organization_id"), `eq.${org}`);
          return Promise.resolve(Response.json(
            url.pathname.endsWith("/campaign_deliveries")
              ? [delivery]
              : [campaign],
          ));
        },
      },
    },
  );
  assertEquals(await readCampaignReplyContext(user, service, input), []);
  assertEquals(serviceRequests, 0);
  allowed = true;
  address = "222";
  assertEquals(await readCampaignReplyContext(user, service, input), []);
  address = campaign.organization_address;
  recipient = "923001234568";
  assertEquals(await readCampaignReplyContext(user, service, input), []);
  recipient = "923001234567";
  const [preview] = await readCampaignReplyContext(user, service, input);
  assertEquals(preview.reply_id, reply);
  assertEquals(preview.body, "Hello Customer");
});
