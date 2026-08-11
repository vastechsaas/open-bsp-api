export type PlatformReportType = "conversations" | "campaigns";

type ReportRow = Record<string, unknown>;

type Column = {
  header: string;
  key?: string;
};

const COMMON_COLUMNS: Column[] = [
  { header: "organization_id", key: "organization_id" },
  { header: "organization_name", key: "organization_name" },
  { header: "report_month_utc", key: "report_month" },
  { header: "period_start_utc", key: "period_start_utc" },
  { header: "period_end_utc", key: "period_end_utc" },
  { header: "generated_at_utc" },
];

const CONVERSATION_COLUMNS: Column[] = [
  ...COMMON_COLUMNS,
  { header: "conversation_id", key: "conversation_id" },
  { header: "channel", key: "service" },
  { header: "business_address", key: "organization_address" },
  { header: "contact_id", key: "contact_id" },
  { header: "customer_name", key: "customer_name" },
  { header: "customer_address", key: "contact_address" },
  { header: "current_status", key: "conversation_status" },
  { header: "assigned_agent_id", key: "assigned_agent_id" },
  { header: "assigned_agent_name", key: "assigned_agent_name" },
  { header: "conversation_created_at_utc", key: "conversation_created_at" },
  { header: "first_activity_at_utc", key: "first_activity_at_utc" },
  { header: "last_activity_at_utc", key: "last_activity_at_utc" },
  { header: "incoming_message_count", key: "incoming_message_count" },
  { header: "outgoing_message_count", key: "outgoing_message_count" },
  { header: "total_message_count", key: "total_message_count" },
];

const CAMPAIGN_COLUMNS: Column[] = [
  ...COMMON_COLUMNS,
  { header: "campaign_id", key: "campaign_id" },
  { header: "campaign_name", key: "campaign_name" },
  { header: "business_address", key: "organization_address" },
  { header: "audience_type", key: "audience_type" },
  { header: "current_status", key: "campaign_status" },
  { header: "created_by_agent_id", key: "created_by_agent_id" },
  { header: "created_by_agent_name", key: "created_by_agent_name" },
  { header: "template_name", key: "template_name" },
  { header: "template_language", key: "template_language" },
  { header: "launched_at_utc", key: "launched_at_utc" },
  { header: "last_updated_at_utc", key: "last_updated_at_utc" },
  { header: "queued_count", key: "queued_count" },
  { header: "processing_count", key: "processing_count" },
  { header: "accepted_count", key: "accepted_count" },
  { header: "failed_count", key: "failed_count" },
  { header: "total_recipient_count", key: "total_recipient_count" },
];

export function escapeCsvCell(value: unknown): string {
  let text = value == null ? "" : String(value);

  // Prevent spreadsheet programs from interpreting tenant data as formulas.
  if (/^[=+\-@]/.test(text)) text = `'${text}`;

  return `"${text.replaceAll('"', '""')}"`;
}

export function buildPlatformReportCsv(
  reportType: PlatformReportType,
  rows: ReportRow[],
  generatedAt: string,
): string {
  const columns = reportType === "conversations"
    ? CONVERSATION_COLUMNS
    : CAMPAIGN_COLUMNS;
  const lines = [
    columns.map((column) => escapeCsvCell(column.header)).join(","),
  ];

  for (const row of rows) {
    lines.push(
      columns.map((column) =>
        escapeCsvCell(column.key ? row[column.key] : generatedAt)
      ).join(","),
    );
  }

  return `${lines.join("\r\n")}\r\n`;
}

export function buildReportFilename(
  organizationName: string,
  reportType: PlatformReportType,
  month: string,
): string {
  const slug = organizationName
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "") || "tenant";

  return `${slug}-${reportType}-${month}.csv`;
}
