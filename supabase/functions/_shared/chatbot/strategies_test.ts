import { assertEquals } from "../test_assert.ts";
import type {
  CollectInputNodeV1,
  ConditionNodeV1,
  ExecutionContextV1,
} from "./flow_definition.ts";
import {
  collectInputNodeStrategy,
  conditionNodeStrategy,
  endNodeStrategy,
  interactiveButtonsNodeStrategy,
  listMessageNodeStrategy,
  sendMessageNodeStrategy,
  startNodeStrategy,
} from "./strategies.ts";

const emptyContext: ExecutionContextV1 = { variables: {} };

const requiredInputNode: CollectInputNodeV1 = {
  id: "collect-city",
  type: "collect_input",
  config: {
    prompt: "What is your city?",
    variable: "customer_city",
    required: true,
    min_length: 2,
    max_length: 20,
  },
};

Deno.test("start advances through the default route", async () => {
  assertEquals(
    await startNodeStrategy.execute(
      { id: "start", type: "start", config: {} },
      emptyContext,
    ),
    { type: "advance", route: { kind: "default" } },
  );
});

Deno.test("send_message emits its literal text", async () => {
  assertEquals(
    await sendMessageNodeStrategy.execute(
      {
        id: "welcome",
        type: "send_message",
        config: { text: "Welcome" },
      },
      emptyContext,
    ),
    {
      type: "emit_message",
      message: { type: "text", text: "Welcome" },
      route: { kind: "default" },
    },
  );
});

Deno.test("interactive button and list strategies wait then route by ID", async () => {
  const buttonNode = {
    id: "buttons",
    type: "interactive_buttons" as const,
    config: {
      body: "Choose",
      buttons: [{ id: "sales", title: "Sales" }],
    },
  };
  const buttonWait = await interactiveButtonsNodeStrategy.execute(
    buttonNode,
    emptyContext,
  );
  assertEquals(buttonWait.type, "wait_for_input");
  assertEquals(
    await interactiveButtonsNodeStrategy.execute(buttonNode, {
      variables: {},
      option_input: { kind: "button", id: "sales" },
    }),
    {
      type: "advance",
      route: { kind: "option", option_id: "sales" },
    },
  );

  const listNode = {
    id: "list",
    type: "list_message" as const,
    config: {
      body: "Choose",
      button_text: "Options",
      sections: [{
        id: "teams",
        title: "Teams",
        rows: [{ id: "support", title: "Support" }],
      }],
    },
  };
  const listWait = await listMessageNodeStrategy.execute(
    listNode,
    emptyContext,
  );
  assertEquals(listWait.type, "wait_for_input");
  assertEquals(
    await listMessageNodeStrategy.execute(listNode, {
      variables: {},
      option_input: { kind: "list_selection", id: "support" },
    }),
    {
      type: "advance",
      route: { kind: "option", option_id: "support" },
    },
  );
});

Deno.test("collect_input prompts when input is absent", async () => {
  assertEquals(
    await collectInputNodeStrategy.execute(requiredInputNode, emptyContext),
    {
      type: "wait_for_input",
      prompt: "What is your city?",
      expectation: {
        kind: "free_text",
        variable: "customer_city",
        required: true,
        min_length: 2,
        max_length: 20,
      },
    },
  );
});

Deno.test("collect_input re-prompts for required and length-invalid text", async () => {
  for (const freeText of ["   ", "A", "x".repeat(21)]) {
    const result = await collectInputNodeStrategy.execute(requiredInputNode, {
      variables: {},
      free_text_input: freeText,
    });

    assertEquals(result.type, "wait_for_input");
  }
});

Deno.test("collect_input accepts optional empty text without applying min length", async () => {
  const result = await collectInputNodeStrategy.execute(
    {
      ...requiredInputNode,
      config: { ...requiredInputNode.config, required: false },
    },
    { variables: {}, free_text_input: "  " },
  );

  assertEquals(result, {
    type: "advance",
    route: { kind: "default" },
    variable_updates: { customer_city: "" },
  });
});

Deno.test("collect_input trims and stores valid text", async () => {
  const result = await collectInputNodeStrategy.execute(requiredInputNode, {
    variables: {},
    free_text_input: "  Lahore  ",
  });

  assertEquals(result, {
    type: "advance",
    route: { kind: "default" },
    variable_updates: { customer_city: "Lahore" },
  });
});

Deno.test("condition routes with a text variable and fails safely when missing", async () => {
  const node: ConditionNodeV1 = {
    id: "route-city",
    type: "condition",
    config: { variable: "customer_city" },
  };

  assertEquals(
    await conditionNodeStrategy.execute(node, {
      variables: { customer_city: "Lahore" },
    }),
    {
      type: "advance",
      route: { kind: "condition", value: "Lahore" },
    },
  );

  assertEquals(
    await conditionNodeStrategy.execute(node, emptyContext),
    {
      type: "fail",
      code: "missing_condition_variable",
      message: "Condition variable customer_city is not available as text",
      details: { variable: "customer_city" },
    },
  );
});

Deno.test("end completes execution", async () => {
  assertEquals(
    await endNodeStrategy.execute(
      { id: "end", type: "end", config: {} },
      emptyContext,
    ),
    { type: "complete" },
  );
});
