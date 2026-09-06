import { loadConfig } from "./config.js";
import { createVoiceServer } from "./server.js";
import { verifyTools } from "./transcoder.js";

const config = loadConfig();
await verifyTools(config);
const server = createVoiceServer(config);
server.listen(config.port, "0.0.0.0", () =>
  console.log(
    JSON.stringify({
      level: "info",
      message: "Voice transcoding service ready",
      port: config.port,
    }),
  ),
);

function shutdown(): void {
  server.close((error) => {
    if (error) console.error(error);
    process.exit(error ? 1 : 0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
