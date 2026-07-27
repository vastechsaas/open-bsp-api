import { assertEquals } from "../_shared/test_assert.ts";
import type { MessageRow } from "../_shared/supabase.ts";
import { chatbotRuntimeTestables } from "./chatbot.ts";

function incomingText(text: string): MessageRow {
  return {
    content: { version: "1", type: "text", kind: "text", text },
  } as MessageRow;
}

function incomingInteractive(
  interactive:
    | { type: "button_reply"; button_reply: { id: string; title: string } }
    | { type: "list_reply"; list_reply: { id: string; title: string } },
): MessageRow {
  return {
    content: {
      version: "1",
      type: "data",
      kind: "interactive",
      data: interactive,
    },
  } as MessageRow;
}

Deno.test("the trigger message does not answer a newly created input node", () => {
  assertEquals(
    chatbotRuntimeTestables.freeTextInput(
      incomingText("hello"),
      true,
      "running",
    ),
    undefined,
  );
});

Deno.test("free text is supplied only when an existing run is waiting", () => {
  const incoming = incomingText("Lahore");

  assertEquals(
    chatbotRuntimeTestables.freeTextInput(incoming, false, "waiting"),
    "Lahore",
  );
  assertEquals(
    chatbotRuntimeTestables.freeTextInput(incoming, false, "running"),
    undefined,
  );
});

Deno.test("interactive replies are supplied only for the expected wait kind", () => {
  const button = incomingInteractive({
    type: "button_reply",
    button_reply: { id: "support", title: "Support" },
  });
  const list = incomingInteractive({
    type: "list_reply",
    list_reply: { id: "sales", title: "Sales" },
  });

  assertEquals(
    chatbotRuntimeTestables.optionInput(
      button,
      false,
      "waiting",
      "button",
    ),
    { kind: "button", id: "support" },
  );
  assertEquals(
    chatbotRuntimeTestables.optionInput(
      list,
      false,
      "waiting",
      "list_selection",
    ),
    { kind: "list_selection", id: "sales" },
  );
  assertEquals(
    chatbotRuntimeTestables.optionInput(
      button,
      false,
      "waiting",
      "list_selection",
    ),
    undefined,
  );
});
