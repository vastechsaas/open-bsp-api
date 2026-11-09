import { csvRow, type ExportDefinition, type ExportRow } from "./csv.ts";

export type ExportJob = ExportDefinition & {
  id: string;
  lease_token: string;
  processed_count: number;
  row_count: number;
};
export type ExportRepository = {
  claim(): Promise<ExportJob | null>;
  rows(job: ExportJob): Promise<ExportRow[]>;
  upload(path: string, content: string): Promise<void>;
  finish(job: ExportJob, success: boolean): Promise<boolean>;
};

export async function processExportPart(
  repo: ExportRepository,
): Promise<boolean> {
  const job = await repo.claim();
  if (!job) return false;
  try {
    const rows = await repo.rows(job);
    if (rows.length !== Math.min(100, job.row_count - job.processed_count)) {
      throw new Error("Incomplete snapshot batch");
    }
    if (rows.length) {
      const path = `${job.id}/${Math.floor(job.processed_count / 100)}.csv`;
      await repo.upload(path, rows.map((row) => csvRow(job, row)).join(""));
    }
    await repo.finish(job, true);
  } catch {
    // Content/addresses/credentials never enter diagnostics. A crash before this
    // checkpoint is recovered by lease expiry; deterministic parts are reusable.
    await repo.finish(job, false);
  }
  return true;
}
