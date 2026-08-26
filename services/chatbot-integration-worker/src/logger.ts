export type LogLevel = "debug" | "info" | "warn" | "error";
export type LogFields = Record<string, unknown>;
export type Logger = Record<
  LogLevel,
  (message: string, fields?: LogFields) => void
>;

const order: LogLevel[] = ["debug", "info", "warn", "error"];
const blockedKeys =
  /(?:api.?key|authorization|signature|raw.?body|payload|secret|token)/i;

export function sanitizeFields(fields: LogFields = {}): LogFields {
  return Object.fromEntries(
    Object.entries(fields).map(([key, value]) => [
      key,
      blockedKeys.test(key) ? "[REDACTED]" : value,
    ]),
  );
}

export function createLogger(minimumLevel: LogLevel = "info"): Logger {
  const threshold = order.indexOf(minimumLevel);
  return Object.fromEntries(order.map((level, index) => [
    level,
    (message: string, fields: LogFields = {}) => {
      if (index < threshold) return;
      const line = JSON.stringify({
        timestamp: new Date().toISOString(),
        level,
        message,
        ...sanitizeFields(fields),
      });
      (level === "error" ? console.error : console.log)(line);
    },
  ])) as Logger;
}
