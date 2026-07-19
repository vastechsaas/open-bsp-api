import { assertEquals } from "../_shared/test_assert.ts";
import {
  buildMetaTemplateDeleteUrl,
  createTemplate,
  deleteTemplateRecord,
  editTemplate,
  isEditableSubmittedTemplateStatus,
} from "./templates.ts";

type FakeResult = { data: unknown; error: null };

async function assertRejects(callback: () => Promise<unknown>) {
  try {
    await callback();
  } catch {
    return;
  }
  throw new Error("Expected promise to reject");
}

class FakeTemplateClient {
  currentStatus = "approved";
  readonly statusUpdates: string[] = [];
  readonly filters: Array<[string, unknown]> = [];

  from(table: string) {
    return new FakeQuery(this, table);
  }

  resolve(query: FakeQuery): FakeResult {
    if (query.table === "organizations_addresses") {
      return {
        data: {
          extra: {
            waba_id: "waba-1",
            access_token: "token-1",
            application_id: "app-1",
          },
        },
        error: null,
      };
    }

    const nextStatus = query.updateValues?.status;
    if (typeof nextStatus === "string") {
      this.currentStatus = nextStatus;
      this.statusUpdates.push(nextStatus);
      return { data: { id: "local-template-1" }, error: null };
    }

    return {
      data: {
        organization_id: "org-1",
        id: "local-template-1",
        organization_address: "account-1",
        external_id: "meta-template-1",
        name: "order_update",
        language: "en_US",
        category: "utility",
        status: this.currentStatus,
        components: [{ type: "BODY", text: "Order ready" }],
      },
      error: null,
    };
  }
}

class FakeQuery implements PromiseLike<FakeResult> {
  updateValues?: Record<string, unknown>;
  private result?: FakeResult;

  constructor(
    private readonly client: FakeTemplateClient,
    readonly table: string,
  ) {}

  select(_columns?: string) {
    return this;
  }

  update(values: Record<string, unknown>) {
    this.updateValues = values;
    return this;
  }

  eq(column: string, value: unknown) {
    this.client.filters.push([column, value]);
    return this;
  }

  single() {
    return Promise.resolve(this.getResult());
  }

  maybeSingle() {
    return Promise.resolve(this.getResult());
  }

  then<TResult1 = FakeResult, TResult2 = never>(
    onfulfilled?:
      | ((value: FakeResult) => TResult1 | PromiseLike<TResult1>)
      | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.getResult()).then(onfulfilled, onrejected);
  }

  private getResult() {
    this.result ||= this.client.resolve(this);
    return this.result;
  }
}

Deno.test("submitted template edit statuses are intentionally limited", () => {
  for (const status of ["pending", "approved", "rejected"]) {
    assertEquals(isEditableSubmittedTemplateStatus(status), true);
  }
  for (const status of ["draft", "paused", "disabled", "deleted"]) {
    assertEquals(isEditableSubmittedTemplateStatus(status), false);
  }
});

Deno.test("template deletion targets the exact Meta ID and name", () => {
  const url = buildMetaTemplateDeleteUrl(
    "waba-1",
    "meta-template-1",
    "order_update",
  );

  assertEquals(url.pathname, "/v24.0/waba-1/message_templates");
  assertEquals(url.searchParams.get("hsm_id"), "meta-template-1");
  assertEquals(url.searchParams.get("name"), "order_update");
});

Deno.test("failed Meta deletion restores the previous local status", async () => {
  const client = new FakeTemplateClient();
  const originalFetch = globalThis.fetch;
  let requestedUrl = "";
  globalThis.fetch = (input) => {
    requestedUrl = String(input);
    return Promise.resolve(
      new Response(JSON.stringify({ error: { message: "Meta failed" } }), {
        status: 500,
        headers: { "content-type": "application/json" },
      }),
    );
  };

  try {
    await assertRejects(() =>
      deleteTemplateRecord(
        client as never,
        "org-1",
        "local-template-1",
      )
    );
  } finally {
    globalThis.fetch = originalFetch;
  }

  assertEquals(client.statusUpdates, ["pending_deletion", "approved"]);
  assertEquals(client.currentStatus, "approved");
  assertEquals(
    client.filters.some(([field, value]) =>
      field === "organization_id" && value === "org-1"
    ),
    true,
  );
  assertEquals(requestedUrl.includes("hsm_id=meta-template-1"), true);
});

Deno.test("media template creation uploads a sample and sends only the temporary handle", async () => {
  const client = new FakeTemplateClient();
  const originalFetch = globalThis.fetch;
  let templateRequest: Record<string, unknown> | undefined;
  globalThis.fetch = (input, init) => {
    const url = String(input);
    if (url.includes("/app-1/uploads")) {
      return Promise.resolve(Response.json({ id: "upload-session-1" }));
    }
    if (url.endsWith("/upload-session-1")) {
      return Promise.resolve(Response.json({ h: "meta-handle-1" }));
    }
    templateRequest = JSON.parse(String(init?.body));
    return Promise.resolve(
      Response.json({
        id: "meta-template-1",
        status: "PENDING",
        category: "UTILITY",
      }),
    );
  };

  try {
    await createTemplate(
      client as never,
      "org-1",
      "account-1",
      {
        id: "",
        name: "monthly_statement",
        status: "PENDING",
        language: "en_US",
        category: "UTILITY",
        components: [
          { type: "HEADER", format: "DOCUMENT" },
          { type: "BODY", text: "Your statement is ready." },
        ],
      },
      new File([new Uint8Array([1])], "statement.pdf", {
        type: "application/pdf",
      }),
    );
  } finally {
    globalThis.fetch = originalFetch;
  }

  assertEquals(
    (templateRequest?.components as Array<unknown>)[0],
    {
      type: "HEADER",
      format: "DOCUMENT",
      example: { header_handle: ["meta-handle-1"] },
    },
  );
});

Deno.test("submitted media template editing uploads a fresh sample", async () => {
  const client = new FakeTemplateClient();
  const originalFetch = globalThis.fetch;
  let editRequest: Record<string, unknown> | undefined;
  globalThis.fetch = (input, init) => {
    const url = String(input);
    if (url.includes("/app-1/uploads")) {
      return Promise.resolve(Response.json({ id: "upload-session-2" }));
    }
    if (url.endsWith("/upload-session-2")) {
      return Promise.resolve(Response.json({ h: "meta-handle-2" }));
    }
    editRequest = JSON.parse(String(init?.body));
    return Promise.resolve(Response.json({ success: true }));
  };

  try {
    await editTemplate(
      client as never,
      "org-1",
      "account-1",
      {
        id: "meta-template-1",
        name: "promotion",
        status: "APPROVED",
        language: "en_US",
        category: "MARKETING",
        components: [
          { type: "HEADER", format: "IMAGE" },
          { type: "BODY", text: "See our latest promotion." },
        ],
      },
      new File([new Uint8Array([1])], "promotion.png", {
        type: "image/png",
      }),
    );
  } finally {
    globalThis.fetch = originalFetch;
  }

  assertEquals((editRequest?.components as Array<unknown>)[0], {
    type: "HEADER",
    format: "IMAGE",
    example: { header_handle: ["meta-handle-2"] },
  });
});
