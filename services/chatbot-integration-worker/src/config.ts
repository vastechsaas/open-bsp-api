import { z } from "zod";
import { type AccountConfig, accountConfigSchema } from "./contracts.js";

export type WorkerConfig = {
  cloudAmqpUrl: string;
  functionsBaseUrl: string;
  accounts: Record<string, AccountConfig>;
  port: number;
  logLevel: "debug" | "info" | "warn" | "error";
};

const environmentSchema = z.object({
  CLOUDAMQP_URL: z.string().url().refine(
    (value) => value.startsWith("amqp://") || value.startsWith("amqps://"),
    "CLOUDAMQP_URL must use amqp:// or amqps://",
  ),
  OPENBSP_FUNCTIONS_BASE_URL: z.string().url(),
  OPENBSP_ACCOUNT_CONFIG_JSON: z.string().min(2),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
});

export function loadConfig(
  environment: NodeJS.ProcessEnv = process.env,
): WorkerConfig {
  const parsed = environmentSchema.parse(environment);
  let rawAccounts: unknown;
  try {
    rawAccounts = JSON.parse(parsed.OPENBSP_ACCOUNT_CONFIG_JSON);
  } catch {
    throw new Error("OPENBSP_ACCOUNT_CONFIG_JSON must be valid JSON");
  }

  const accounts = z.record(accountConfigSchema).parse(rawAccounts);
  if (Object.keys(accounts).length === 0) {
    throw new Error(
      "OPENBSP_ACCOUNT_CONFIG_JSON must define at least one integration",
    );
  }

  return {
    cloudAmqpUrl: parsed.CLOUDAMQP_URL,
    functionsBaseUrl: parsed.OPENBSP_FUNCTIONS_BASE_URL.replace(/\/$/, ""),
    accounts,
    port: parsed.PORT,
    logLevel: parsed.LOG_LEVEL,
  };
}
