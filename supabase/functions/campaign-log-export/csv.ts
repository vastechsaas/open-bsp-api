import type { Json } from "../_shared/db_types.ts";
import { campaignReplyPreview } from "../whatsapp-management/campaign_reply_context.ts";

export const csvHeader = "\uFEFF" + [
  "Date",
  "Time",
  "Recipient number",
  "Sender number",
  "Display name",
  "Status",
].map(csvCell).join(",") + "\r\n";

// Private parts use the original quoted seven-field layout. Project them on
// download, including files generated before this patch. Do not split on lines:
// carousel text may contain embedded newlines and escaped quotes. Keeping the
// internal writer unchanged also makes rolling deployment safe for old workers.
export function csvDownloadPart(part: string): string {
  let offset = 0;
  const rows: string[] = [];
  const invalid = () => new Error("Invalid export CSV part");
  while (offset < part.length) {
    const cells: string[] = [];
    while (true) {
      const start = offset;
      if (part[offset++] !== '"') throw invalid();
      let closed = false;
      while (offset < part.length) {
        if (part[offset++] !== '"') continue;
        if (part[offset] === '"') {
          offset++;
          continue;
        }
        closed = true;
        break;
      }
      if (!closed) throw invalid();
      cells.push(part.slice(start, offset));
      if (cells.length > 7) throw invalid();
      if (part[offset] === ",") {
        offset++;
        continue;
      }
      if (part.slice(offset, offset + 2) === "\r\n") offset += 2;
      else if (offset !== part.length) throw invalid();
      break;
    }
    if (cells.length === 7) cells.splice(2, 1);
    else if (cells.length !== 6) throw invalid();
    rows.push(cells.join(",") + "\r\n");
  }
  return rows.join("");
}

export function csvCell(value: string): string {
  // Protect formulas even after leading whitespace/control characters. Also
  // preserves '+' on international phone numbers when opened in a spreadsheet.
  const safe = /^[=+\-@]/.test(value.replace(/^[\s\p{Cc}]*/u, "")) ||
      /^[\t\r\n]/.test(value)
    ? `'${value}`
    : value;
  return `"${safe.replaceAll('"', '""')}"`;
}

export type ExportDefinition = {
  organization_id: string;
  timezone: string;
  template: Json;
  mapping: Json;
  sender_number: string;
  display_name: string;
};
export type ExportRow = {
  sent_at: string | null;
  recipient: string;
  recipient_name: string | null;
  variables: Json;
  status: string;
};

export function csvRow(job: ExportDefinition, row: ExportRow): string {
  const preview = campaignReplyPreview({
    name: "",
    organization_address: "",
    template: job.template,
    template_variable_mapping: job.mapping,
    carousel_media: [],
  }, {
    contact_address: row.recipient,
    name: row.recipient_name,
    variables: row.variables,
  }, job.organization_id);
  const links = (items: typeof preview.links) =>
    items.map((link) => `${link.label}: ${link.url}`).join("\n");
  const content = [
    preview.header,
    preview.body,
    preview.footer,
    links(preview.links),
    ...preview.cards.map((card) =>
      [card.text, links(card.links)].filter(Boolean).join("\n")
    ),
  ].filter(Boolean).join("\n\n");
  let date = "", time = "";
  if (row.sent_at) {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: job.timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(row.sent_at));
    const part = (type: string) => parts.find((p) => p.type === type)!.value;
    date = `${part("year")}-${part("month")}-${part("day")}`;
    time = `${part("hour")}:${part("minute")}:${part("second")}`;
  }
  return [
    date,
    time,
    content,
    row.recipient,
    job.sender_number,
    job.display_name,
    row.status,
  ]
    .map(csvCell).join(",") + "\r\n";
}
