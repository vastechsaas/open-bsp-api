import { assertEquals } from "../test_assert.ts";
import {
  formatResponseList,
  isResponseListFormat,
  type ResponseListFormat,
  responseValueAtPath,
} from "./response_format.ts";
import { mapWebhookResponse } from "./webhook.ts";
import { flowNodeV1Schema, type WebhookNodeV1 } from "./flow_definition.ts";
import { compileFlowDefinition } from "./compiler.ts";
import { translatePublishedDefinition } from "./node_bridge_translation.ts";
import { simulateChatbotFlow } from "../../chatbot-management/simulation.ts";

const format: ResponseListFormat = {
  kind: "list",
  item_template:
    "{{index}}. {{item.name}}: {{item.price}} {{response.currency}}\n{{item.features}}",
  separator: "\n\n",
  array_separator: ", ",
  empty_text: "No items available.",
  max_items: 20,
};
const response = {
  currency: "PKR",
  plans: [{
    name: "Gold",
    price: "1499",
    features: ["Messaging", "Profile views"],
  }, { name: "Silver", price: "999", features: ["Messaging"] }],
};
const expected =
  "1. Gold: 1499 PKR\nMessaging, Profile views\n\n2. Silver: 999 PKR\nMessaging";
const config: WebhookNodeV1["config"] = {
  method: "POST",
  url: "https://api.example.com/items",
  headers: [],
  timeout_ms: 3000,
  retry_count: 0,
  response_mappings: [{ path: "plans", variable: "items_text", format }],
};

Deno.test("formats arbitrary collections and nested scalar arrays without API-specific logic", () => {
  assertEquals(formatResponseList(response.plans, response, format), {
    ok: true,
    text: expected,
  });
  assertEquals(
    formatResponseList([{ name: "Appointment", price: 0, features: [false] }], {
      currency: "USD",
    }, format),
    { ok: true, text: "1. Appointment: 0 USD\nfalse" },
  );
  assertEquals(
    formatResponseList(["A", "B"], {}, {
      ...format,
      item_template: "{{item}}",
    }),
    { ok: true, text: "A\n\nB" },
  );
});

Deno.test("own-property paths support numeric indexes and root, never prototype access", () => {
  assertEquals(responseValueAtPath(response, "plans.0.name"), "Gold");
  assertEquals(responseValueAtPath(response.plans, "$"), response.plans);
  for (
    const path of [
      "constructor",
      "plans.__proto__",
      "plans.01.name",
      "plans[-1]",
      "toString",
    ]
  ) assertEquals(responseValueAtPath(response, path), undefined);
});

Deno.test("empty lists have explicit copy; wrong types, missing fields, objects and limits fail", () => {
  assertEquals(formatResponseList([], {}, format), {
    ok: true,
    text: "No items available.",
  });
  for (
    const [value, code] of [[{}, "response_format_array_required"], [
      [{}],
      "response_format_field_missing",
    ], [
      [{ name: {}, price: 1, features: [] }],
      "response_format_scalar_required",
    ]] as const
  ) {
    assertEquals(formatResponseList(value, response, format), {
      ok: false,
      code,
    });
  }
  assertEquals(
    formatResponseList(response.plans, response, { ...format, max_items: 1 }),
    { ok: false, code: "response_format_too_many_items" },
  );
  assertEquals(
    formatResponseList(["x".repeat(4097)], {}, {
      ...format,
      item_template: "{{item}}",
    }),
    { ok: false, code: "response_format_too_long" },
  );
  for (
    const item_template of [
      "{{env.API_KEY}}",
      "{{item.name",
      "{{item.constructor}}",
      "{{item.name()}}",
      "{{input}}",
      "}}",
      " ",
    ]
  ) assertEquals(isResponseListFormat({ ...format, item_template }), false);
  assertEquals(isResponseListFormat({ ...format, max_items: 51 }), false);
  assertEquals(isResponseListFormat({ ...format, execute: "script" }), false);
});

Deno.test("legacy scalar mappings stay unchanged; formatted mappings are atomic and validated", () => {
  const node: WebhookNodeV1 = { id: "api", type: "webhook", config };
  assertEquals(mapWebhookResponse(node, response), {
    ok: true,
    variable_updates: { items_text: expected },
  });
  assertEquals(
    mapWebhookResponse({
      ...node,
      config: {
        ...config,
        response_mappings: [{ path: "currency", variable: "currency" }],
      },
    }, response),
    { ok: true, variable_updates: { currency: "PKR" } },
  );
  assertEquals(
    mapWebhookResponse({
      ...node,
      config: {
        ...config,
        response_mappings: [{ path: "currency", variable: "currency" }, {
          path: "missing",
          variable: "items_text",
          format,
        }],
      },
    }, response),
    { ok: false, error_code: "response_format_array_required" },
  );
  assertEquals(flowNodeV1Schema.safeParse(node).success, true);
});

const node = (id: string, node_type: string, config = {}) => ({
  id,
  data: { node_type, config },
});
const graph = {
  nodes: [
    node("start", "start"),
    node("api", "webhook", config),
    node("ok", "send_message", { text: "{{items_text}}" }),
    node("error", "send_message", { text: "API result unavailable." }),
    node("end", "end"),
  ],
  edges: [
    { id: "a", source: "start", target: "api", data: { kind: "default" } },
    {
      id: "b",
      source: "api",
      target: "ok",
      data: { kind: "webhook", outcome: "success" },
    },
    {
      id: "c",
      source: "api",
      target: "error",
      data: { kind: "webhook", outcome: "error" },
    },
    { id: "d", source: "ok", target: "end", data: { kind: "default" } },
    { id: "e", source: "error", target: "end", data: { kind: "default" } },
  ],
};

Deno.test("compiler and Node translation retain the reusable format contract", () => {
  const compiled = compileFlowDefinition(graph);
  assertEquals(compiled.ok, true);
  if (!compiled.ok) return;
  const translated = translatePublishedDefinition(compiled.definition);
  const api = translated.nodes.find((item) => item.id === "api")!;
  assertEquals(api.data.config.responseMapping, [{
    variableName: "items_text",
    jsonPath: "plans",
    format,
  }]);
  const invalid = structuredClone(graph);
  invalid.nodes[1].data.config = {
    ...config,
    response_mappings: [{
      path: "plans",
      variable: "items_text",
      format: { ...format, item_template: "{{env.SECRET}}" },
    }],
  };
  const result = compileFlowDefinition(invalid);
  assertEquals(result.ok, false);
  if (!result.ok) {
    assertEquals(result.issues.map((issue) => issue.code), [
      "webhook_response_format_invalid",
    ]);
  }
});

Deno.test("simulation and execution share success/error formatting, without live API calls", async () => {
  for (
    const [body, texts] of [[response, [expected]], [{ plans: [{}] }, [
      "API result unavailable.",
    ]]] as const
  ) {
    const result = await simulateChatbotFlow(graph, {
      variables: {},
      webhook_mocks: { api: { outcome: "success", status_code: 200, body } },
    });
    assertEquals(result.valid, true);
    if (result.valid) assertEquals(result.outgoing_texts, texts);
  }
});
