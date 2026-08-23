import { createServer, type Server } from "node:http";
import type { WorkerState } from "./state.js";

export function startHealthServer(
  state: WorkerState,
  port: number,
): Promise<Server> {
  const server = createServer((request, response) => {
    if (request.url === "/healthz") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ status: "alive" }));
      return;
    }
    if (request.url === "/readyz") {
      const ready = state.connected && state.consuming && !state.shuttingDown;
      response.writeHead(ready ? 200 : 503, {
        "Content-Type": "application/json",
      });
      response.end(JSON.stringify({
        status: ready ? "ready" : "not_ready",
        connected: state.connected,
        consuming: state.consuming,
        in_flight: state.inFlight,
        processed: state.processed,
        dead_lettered: state.deadLettered,
        last_success_at: state.lastSuccessAt,
        last_failure_at: state.lastFailureAt,
      }));
      return;
    }
    response.writeHead(404).end();
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "0.0.0.0", () => resolve(server));
  });
}
