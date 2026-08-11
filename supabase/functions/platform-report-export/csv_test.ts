import { assertEquals, assertStringIncludes } from "jsr:@std/assert";
import {
  buildPlatformReportCsv,
  buildReportFilename,
  escapeCsvCell,
} from "./csv.ts";

Deno.test("CSV cells are quoted and spreadsheet formulas are neutralized", () => {
  assertEquals(escapeCsvCell('Hello, "Sara"'), '"Hello, ""Sara"""');
  assertEquals(escapeCsvCell("=SUM(1,2)"), '"\'=SUM(1,2)"');
  assertEquals(escapeCsvCell("+923001234567"), '"\'+923001234567"');
});

Deno.test("empty reports contain a stable header row", () => {
  const csv = buildPlatformReportCsv(
    "conversations",
    [],
    "2026-08-11T00:00:00.000Z",
  );

  assertStringIncludes(csv, '"organization_id","organization_name"');
  assertEquals(csv.split("\r\n").filter(Boolean).length, 1);
});

Deno.test("report filenames are deterministic and safe", () => {
  assertEquals(
    buildReportFilename("Hamza WABA / Pakistan", "campaigns", "2026-07"),
    "hamza-waba-pakistan-campaigns-2026-07.csv",
  );
});
