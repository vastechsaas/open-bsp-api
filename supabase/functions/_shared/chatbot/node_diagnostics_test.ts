import { assertEquals } from "../test_assert.ts";
import { compileFlowDefinition } from "./compiler.ts";
import { simulateChatbotFlow } from "../../chatbot-management/simulation.ts";

function diagnostics(type: string, config: Record<string, unknown>) {
  const result = compileFlowDefinition({
    nodes: [
      { id: "start", data: { node_type: "start", config: {} } },
      { id: "test", data: { node_type: type, config } },
      { id: "end", data: { node_type: "end", config: {} } },
    ],
    edges: [
      { id: "a", source: "start", target: "test" },
      { id: "b", source: "test", target: "end" },
    ],
  });
  if (result.ok) throw new Error("Expected invalid fixture");
  return result.issues.filter((issue) => issue.category === "configuration");
}

Deno.test("DKR regression: two button titles retain their precise paths and limits", () => {
  const issues = diagnostics("list_message", {
    body: "Choose",
    button_text: "Open",
    render_as_buttons: true,
    sections: [{
      id: "s",
      title: "Profile",
      rows: [
        { id: "a", title: "Edit my account" },
        { id: "b", title: "Report an accounts" },
        { id: "c", title: "Non relevant settings" },
        { id: "d", title: "No information showing" },
      ],
    }],
  });
  assertEquals(issues.length, 2);
  assertEquals(
    issues.map(({ code, field_path, params }) => ({
      code,
      field_path,
      params,
    })),
    [
      {
        code: "button_title_too_long",
        field_path: ["sections", 0, "rows", 2, "title"],
        params: { option: 3, limit: 20, actual: 21 },
      },
      {
        code: "button_title_too_long",
        field_path: ["sections", 0, "rows", 3, "title"],
        params: { option: 4, limit: 20, actual: 22 },
      },
    ],
  );
});

Deno.test("menu diagnostics distinguish missing, malformed, oversized and duplicate options", () => {
  for (const buttons of [undefined, []]) {
    assertEquals(
      diagnostics("interactive_buttons", { body: "Choose", buttons }).map((i) =>
        i.code
      ),
      ["options_required"],
    );
  }
  const cases: [unknown, string][] = [
    ["not an array", "options_invalid"],
    [[{ id: "a", title: "" }], "option_title_required"],
    [[{ id: "a", title: 42 }], "option_title_invalid"],
    [[{ id: "!", title: "Yes" }], "option_id_invalid"],
    [[{ id: "a", title: "x".repeat(21) }], "button_title_too_long"],
    [
      Array.from({ length: 4 }, (_, n) => ({ id: `a${n}`, title: "Yes" })),
      "option_count_exceeded",
    ],
    [
      [{ id: "a", title: "Yes" }, { id: "a", title: "No" }],
      "option_id_duplicate",
    ],
  ];
  for (const [buttons, code] of cases) {
    assertEquals(
      diagnostics("interactive_buttons", { body: "Choose", buttons }).map((i) =>
        i.code
      ),
      [code],
    );
  }
});

Deno.test("stricter button limit is reported once even above ordinary list limit", () => {
  const base = {
    body: "Choose",
    button_text: "Open",
    sections: [{
      id: "s",
      title: "Group",
      rows: [{ id: "r", title: "x".repeat(25) }],
    }],
  };
  assertEquals(diagnostics("list_message", base).map((i) => i.code), [
    "list_title_too_long",
  ]);
  assertEquals(
    diagnostics("list_message", { ...base, render_as_buttons: true }).map((i) =>
      i.code
    ),
    ["button_title_too_long"],
  );
});

Deno.test("text menu duplicates point to the duplicate value, not the entire options array", () => {
  const issues = diagnostics("text_menu", {
    prompt: "Choose",
    variable: "choice",
    invalid_response: "Again",
    options: [{ id: "a", label: "One", value: "YES" }, {
      id: "b",
      label: "Two",
      value: " yes ",
    }],
  });
  assertEquals(issues.map((i) => i.code), ["option_value_duplicate"]);
  assertEquals(issues[0].field_path, ["options", 1, "value"]);
});

Deno.test("other nodes distinguish required fields, format errors and size/range errors", () => {
  assertEquals(
    diagnostics("send_message", { text: "x".repeat(4097) })[0].code,
    "field_too_long",
  );
  assertEquals(
    diagnostics("send_message", { text: 4 })[0].code,
    "field_invalid",
  );
  assertEquals(
    diagnostics("collect_input", {
      prompt: "x".repeat(4097),
      variable: "answer",
      required: true,
    })[0].code,
    "field_too_long",
  );
  assertEquals(
    diagnostics("collect_input", {
      prompt: "Answer",
      variable: "answer",
      required: true,
      min_length: 8,
      max_length: 3,
    })[0].code,
    "input_length_range_invalid",
  );
  assertEquals(
    diagnostics("condition", { variable: "" })[0].code,
    "condition_variable_required",
  );
  assertEquals(
    diagnostics("condition", { variable: "BAD NAME" })[0].code,
    "condition_variable_invalid",
  );
  assertEquals(
    diagnostics("assign_agent", { routing_queue_id: "broken" })[0].code,
    "handoff_queue_invalid",
  );
});

Deno.test("webhook diagnostics are safe and preserve independent nested errors", () => {
  const issues = diagnostics("webhook", {
    method: "GET",
    url: "https://example.com",
    headers: [{ name: "X-Api-Key", value: "never-return-this-secret" }],
    timeout_ms: 10001,
    retry_count: -1,
    secret_id: "broken",
    response_mappings: [{ variable: "BAD", path: "bad[]" }],
  });
  assertEquals(
    issues.some((i) => i.code === "webhook_credential_required"),
    true,
  );
  assertEquals(
    issues.some((i) => i.code === "webhook_credential_invalid"),
    true,
  );
  assertEquals(issues.some((i) => i.code === "field_above_maximum"), true);
  assertEquals(issues.some((i) => i.code === "field_below_minimum"), true);
  assertEquals(
    JSON.stringify(issues).includes("never-return-this-secret"),
    false,
  );
  assertEquals(issues.filter((i) => i.field === "response_mappings").length, 2);
});

Deno.test("missing handoff destination does not hide an independent acknowledgment error", () => {
  assertEquals(
    diagnostics("assign_agent", { acknowledgment_text: "" }).map((i) => i.code)
      .sort(),
    ["field_required", "handoff_queue_required"],
  );
});

Deno.test("simulation returns the same precise diagnostics as validation and publishing compiler", async () => {
  const graph = {
    nodes: [
      { id: "start", data: { node_type: "start", config: {} } },
      {
        id: "menu",
        data: {
          node_type: "interactive_buttons",
          config: {
            body: "Choose",
            buttons: [{ id: "a", title: "x".repeat(21) }, {
              id: "b",
              title: "x".repeat(22),
            }],
          },
        },
      },
      { id: "end", data: { node_type: "end", config: {} } },
    ],
    edges: [
      { id: "a", source: "start", target: "menu" },
      {
        id: "b",
        source: "menu",
        target: "end",
        data: { kind: "option", option_id: "a" },
      },
      {
        id: "c",
        source: "menu",
        target: "end",
        data: { kind: "option", option_id: "b" },
      },
    ],
  };
  const compiled = compileFlowDefinition(graph);
  const simulated = await simulateChatbotFlow(graph, { variables: {} });
  if (compiled.ok || simulated.valid) throw new Error("Expected invalid graph");
  assertEquals(simulated.issues, compiled.issues);
  assertEquals(compiled.issues.length, 2);
});
