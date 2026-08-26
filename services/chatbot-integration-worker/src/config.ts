import { z } from "zod";
import { type AccountConfig, accountConfigSchema } from "./contracts.js";
import { defaultTopology, type QueueTopology } from "./topology.js";

export type WorkerConfig = {
  cloudAmqpUrl: string;
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  functionsBaseUrl: string;
  accounts: Record<string, AccountConfig>;
  port: number;
  logLevel: "debug" | "info" | "warn" | "error";
  topology: QueueTopology;
  acceptedEventTypes: ReadonlySet<"whatsapp_webhook" | "chatbot_reply">;
};

const environmentSchema = z.object({
  CLOUDAMQP_URL: z.string().url().refine(
    (value) => value.startsWith("amqp://") || value.startsWith("amqps://"),
    "CLOUDAMQP_URL must use amqp:// or amqps://",
  ),
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),
  OPENBSP_FUNCTIONS_BASE_URL: z.string().url(),
  OPENBSP_ACCOUNT_CONFIG_JSON: z.string().min(2),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  RABBITMQ_EXCHANGE: z.string().min(1).default(defaultTopology.exchange),
  RABBITMQ_QUEUE: z.string().min(1).default(defaultTopology.queue),
  RABBITMQ_ROUTING_KEY: z.string().min(1).default(defaultTopology.routingKey),
  RABBITMQ_DLX: z.string().min(1).default(defaultTopology.deadLetterExchange),
  RABBITMQ_DLQ: z.string().min(1).default(defaultTopology.deadLetterQueue),
  RABBITMQ_DLQ_ROUTING_KEY: z.string().min(1).default(
    defaultTopology.deadLetterRoutingKey,
  ),
  WORKER_EVENT_TYPES: z.string().default("whatsapp_webhook,chatbot_reply"),
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

  const eventTypeResult = z.array(
    z.enum(["whatsapp_webhook", "chatbot_reply"]),
  ).min(1).safeParse(
    parsed.WORKER_EVENT_TYPES.split(",").map((value) => value.trim()).filter(
      Boolean,
    ),
  );
  if (!eventTypeResult.success) {
    throw new Error("WORKER_EVENT_TYPES contains an unsupported event type");
  }

  return {
    cloudAmqpUrl: parsed.CLOUDAMQP_URL,
    supabaseUrl: parsed.SUPABASE_URL,
    supabaseServiceRoleKey: parsed.SUPABASE_SERVICE_ROLE_KEY,
    functionsBaseUrl: parsed.OPENBSP_FUNCTIONS_BASE_URL.replace(/\/$/, ""),
    accounts,
    port: parsed.PORT,
    logLevel: parsed.LOG_LEVEL,
    topology: {
      exchange: parsed.RABBITMQ_EXCHANGE,
      queue: parsed.RABBITMQ_QUEUE,
      routingKey: parsed.RABBITMQ_ROUTING_KEY,
      deadLetterExchange: parsed.RABBITMQ_DLX,
      deadLetterQueue: parsed.RABBITMQ_DLQ,
      deadLetterRoutingKey: parsed.RABBITMQ_DLQ_ROUTING_KEY,
    },
    acceptedEventTypes: new Set(eventTypeResult.data),
  };
}
