import {
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "jsr:@std/assert";
import {
  csvCell,
  csvDownloadPart,
  csvHeader,
  csvRow,
  type ExportDefinition,
  type ExportRow,
} from "./csv.ts";
import { type ExportJob, processExportPart } from "./worker.ts";

const definition: ExportDefinition = {
  organization_id: "10000000-0000-4000-8000-000000000001",
  timezone: "Asia/Karachi",
  sender_number: "+923001234567",
  display_name: "نمونہ",
  template: { components: [{ type: "BODY", text: "Hello {{1}}" }] },
  mapping: { "body.1": "contact.name" },
};
const row: ExportRow = {
  sent_at: "2026-11-09T21:30:01Z",
  recipient: "+923009999999",
  recipient_name: 'A, "B"',
  variables: {},
  status: "Delivered",
};
Deno.test("CSV protects formulas, quotes, line breaks and international numbers", () => {
  for (
    const value of [
      "=1+1",
      "+92300",
      "-1",
      "@cmd",
      "  =1",
      "\tdata",
      "\rdata",
      "\n+1",
    ]
  ) {
    assertEquals(csvCell(value).startsWith("\"'"), true);
  }
  assertEquals(csvCell('Hello, "world"\nاردو'), '"Hello, ""world""\nاردو"');
  assertEquals(csvHeader.startsWith("\uFEFF"), true);
  assertEquals(csvHeader.includes("Failure"), false);
  assertEquals(
    csvHeader,
    '\uFEFF"Date","Time","Recipient number","Sender number","Display name","Status"\r\n',
  );
});
Deno.test("downloads remove multiline content from existing parts without shifting recipient/status cells", () => {
  const fields = [
    "2026-11-10",
    "02:30:01",
    'Intro, "offer"\r\nCard 1\nhttps://shop.test/item\nCard 2',
    row.recipient,
    definition.sender_number,
    'Name, "quoted"',
    "Delivered",
  ];
  const old = fields.map(csvCell).join(",") + "\r\n";
  const expected =
    fields.filter((_, index) => index !== 2).map(csvCell).join(",") + "\r\n";
  assertEquals(csvDownloadPart(old), expected);
  assertEquals(csvDownloadPart(old + expected), expected + expected);
  assertEquals(csvDownloadPart(old).split("\r\n").filter(Boolean).length, 1);
  assertEquals(
    csvDownloadPart(csvRow(definition, { ...row, status: "" })).endsWith(
      ',""\r\n',
    ),
    true,
  );
  assertEquals(csvDownloadPart(""), "");
});
Deno.test("malformed cached parts fail safely rather than shift columns or omit rows", () => {
  for (
    const part of [
      '"unterminated',
      '"a","b"\r\n',
      "unquoted,fields",
      '"a"garbage',
    ]
  ) {
    assertThrows(() => csvDownloadPart(part), Error, "Invalid export CSV part");
  }
});
Deno.test("CSV uses campaign timezone, personalized content, blank unknowns and missing times", () => {
  const csv = csvRow(definition, row);
  assertStringIncludes(csv, '"2026-11-10","02:30:01"');
  assertStringIncludes(csv, '"Hello A, ""B"""');
  assertStringIncludes(csv, "نمونہ");
  assertStringIncludes(csv, '"Delivered"');
  const unknown = csvRow(definition, { ...row, status: "", sent_at: null });
  assertEquals(unknown.startsWith('"","",'), true);
  assertEquals(unknown.endsWith(',""\r\n'), true);
});
Deno.test("carousel export includes ordered card text and personalized website links, never image URLs", () => {
  const csv = csvRow({
    ...definition,
    mapping: {
      "carousel.0.body.1": "csv.product",
      "carousel.0.button.0.1": "csv.sku",
    },
    template: {
      components: [{ type: "BODY", text: "Intro" }, {
        type: "CAROUSEL",
        cards: [
          {
            components: [{ type: "BODY", text: "Buy {{1}}" }, {
              type: "BUTTONS",
              buttons: [{
                type: "URL",
                text: "Shop",
                url: "https://shop.test/products/{{1}}",
              }],
            }],
          },
          { components: [{ type: "BODY", text: "Second card" }] },
        ],
      }],
    },
  }, { ...row, variables: { product: "Glasses", sku: "abc" } });
  assertStringIncludes(
    csv,
    "Intro\n\nBuy Glasses\nShop: https://shop.test/products/abc\n\nSecond card",
  );
  assertEquals(csv.includes("internal://"), false);
});
Deno.test("worker checkpoints only uploaded deterministic parts and retries safely", async () => {
  const job: ExportJob = {
    ...definition,
    id: "export",
    lease_token: "token",
    processed_count: 100,
    row_count: 101,
  };
  const checkpoints: boolean[] = [];
  const paths: string[] = [];
  let fail = true;
  const repo = {
    claim: () => Promise.resolve(job),
    rows: () => Promise.resolve([row]),
    upload: (path: string, _content: string) => {
      paths.push(path);
      return fail
        ? Promise.reject(new Error("Storage down"))
        : Promise.resolve();
    },
    finish: (_job: ExportJob, success: boolean) => {
      checkpoints.push(success);
      return Promise.resolve(true);
    },
  };
  await processExportPart(repo);
  fail = false;
  await processExportPart(repo);
  assertEquals(paths, ["export/1.csv", "export/1.csv"]);
  assertEquals(checkpoints, [false, true]);
  repo.rows = () => Promise.resolve([]);
  await processExportPart(repo);
  assertEquals(checkpoints, [false, true, false]);
});
