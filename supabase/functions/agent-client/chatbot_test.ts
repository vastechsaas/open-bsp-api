import { assertEquals } from "../_shared/test_assert.ts";
import type { MessageRow } from "../_shared/supabase.ts";
import { chatbotRuntimeTestables } from "./chatbot.ts";

function incomingText(text: string): MessageRow {
  return {
    content: { version: "1", type: "text", kind: "text", text },
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
