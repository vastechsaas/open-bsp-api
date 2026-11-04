import { createClient } from "@supabase/supabase-js";
import { assertEquals } from "../_shared/test_assert.ts";
import type { Database } from "../_shared/supabase.ts";
import {
  campaignConversationHistoryRequest,
  compareHistoryEntries,
  olderTimelineFilter,
  readCampaignConversationHistory,
} from "./campaign_conversation_history.ts";

const org = "6c805acd-0b8c-4581-bb95-2eec9fdc558d";
const conversation = "ee337b4b-9cec-49c2-afce-f47c937176a0";
const time = "2026-11-04T18:12:00.000001+00:00";
const id = (i: number) =>
  `ee337b4b-9cec-49c2-afce-${String(i).padStart(12, "0")}`;
const input = { organization_id: org, conversation_id: conversation };
const campaign = {
  name: "New arrivals",
  organization_address: "111",
  template: { components: [{ type: "BODY", text: "Look at this watch" }] },
  template_variable_mapping: {},
  carousel_media: [],
};

Deno.test("timeline cursor preserves database timestamp precision and handles equal IDs", () => {
  const cursor = { id: id(2), timestamp: time, source: "message" as const };
  assertEquals(
    campaignConversationHistoryRequest.safeParse({ ...input, cursor }).success,
    true,
  );
  assertEquals(
    campaignConversationHistoryRequest.safeParse({
      ...input,
      cursor: { ...cursor, timestamp: "2026-11-04T18:12:00Z),id.not.is.null" },
    }).success,
    false,
  );
  assertEquals(
    Math.sign(compareHistoryEntries(
      cursor,
      { ...cursor, id: id(5), timestamp: "2026-11-04T18:12:00.000000Z" },
    )),
    1,
  );
  assertEquals(
    Math.sign(compareHistoryEntries(cursor, { ...cursor, source: "campaign" })),
    1,
  );
  assertEquals(
    olderTimelineFilter("updated_at", cursor, "campaign").includes("id.lte."),
    true,
  );
  assertEquals(
    olderTimelineFilter("timestamp", cursor, "message").includes("id.lt."),
    true,
  );
});

Deno.test("unquoted replies unlock same-sender campaign history; hidden and outbound-only chats do not", async () => {
  let canRead = false;
  let customerReplied = false;
  let suppressDuplicate = false;
  let reads = 0;
  const user = createClient<Database>("https://user.example.test", "key", {
    auth: { persistSession: false },
    global: {
      fetch: (request) => {
        const url = new URL(String(request));
        const p = url.searchParams;
        assertEquals(p.get("organization_id"), `eq.${org}`);
        if (url.pathname.endsWith("/conversations")) {
          assertEquals(p.get("id"), `eq.${conversation}`);
          assertEquals(p.get("group_address"), "is.null");
          return Promise.resolve(Response.json(
            canRead
              ? [{
                id: conversation,
                contact_address: "+923001234567",
                organization_address: "111",
              }]
              : [],
          ));
        }
        assertEquals(p.get("conversation_id"), `eq.${conversation}`);
        if (p.get("select") === "id") {
          assertEquals(p.get("direction"), "eq.incoming");
          return Promise.resolve(
            Response.json(customerReplied ? [{ id: id(35) }] : []),
          );
        }
        if (p.get("select") === "external_id") {
          return Promise.resolve(
            Response.json(
              suppressDuplicate ? [{ external_id: "wamid.34" }] : [],
            ),
          );
        }
        return Promise.resolve(Response.json(
          customerReplied && !p.has("or")
            ? [{
              id: id(35),
              timestamp: time,
              content: { text: "Is it available?" },
            }]
            : [],
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
          reads++;
          const p = new URL(String(request)).searchParams;
          assertEquals(p.get("organization_id"), `eq.${org}`);
          assertEquals(p.get("campaign.organization_address"), "eq.111");
          assertEquals(p.get("status"), "eq.accepted");
          assertEquals(
            p.get("contact_address"),
            "in.(923001234567,+923001234567)",
          );
          assertEquals(p.get("limit"), "31");
          const ids = p.has("or")
            ? [5, 4]
            : Array.from({ length: 31 }, (_, index) => 34 - index);
          return Promise.resolve(Response.json(
            ids.map((deliveryId) => ({
              id: id(deliveryId),
              updated_at: time,
              external_id: `wamid.${deliveryId}`,
              contact_address: "923001234567",
              name: null,
              variables: {},
              campaign,
            })),
          ));
        },
      },
    },
  );
  assertEquals(await readCampaignConversationHistory(user, service, input), {
    accessible: false,
  });
  canRead = true;
  const noReply = await readCampaignConversationHistory(user, service, input);
  assertEquals(noReply.accessible && noReply.campaigns.length, 0);
  assertEquals(reads, 0);
  customerReplied = true;
  const history = await readCampaignConversationHistory(user, service, input);
  if (!history.accessible) throw new Error("Missing history");
  assertEquals(history.messages.length, 1);
  assertEquals(history.campaigns.length, 29);
  assertEquals(history.campaigns[0].body, "Look at this watch");
  assertEquals(history.next_cursor, {
    id: id(6),
    timestamp: time,
    source: "campaign",
  });
  const older = await readCampaignConversationHistory(user, service, {
    ...input,
    cursor: history.next_cursor,
  });
  if (!older.accessible) throw new Error("Missing older history");
  assertEquals(older.campaigns.map(({ id }) => id), [id(5), id(4)]);
  assertEquals(older.next_cursor, undefined);
  suppressDuplicate = true;
  const deduplicated = await readCampaignConversationHistory(
    user,
    service,
    input,
  );
  assertEquals(deduplicated.accessible && deduplicated.campaigns.length, 28);
});
