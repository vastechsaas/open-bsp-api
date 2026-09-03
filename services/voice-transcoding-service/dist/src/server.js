import { createServer, } from "node:http";
import { authorizeTenant } from "./auth.js";
import { transcodeVoice } from "./transcoder.js";
function json(response, status, body) {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(body));
}
async function readBody(request, limit) {
    const chunks = [];
    let size = 0;
    for await (const chunk of request) {
        const buffer = Buffer.isBuffer(chunk)
            ? chunk
            : Buffer.from(chunk);
        size += buffer.length;
        if (size > limit)
            throw new Error("recording exceeds upload limit");
        chunks.push(buffer);
    }
    return Buffer.concat(chunks);
}
export function createVoiceServer(config, dependencies = {
    authorize: authorizeTenant,
    transcode: transcodeVoice,
}) {
    let activeJobs = 0;
    const handleRequest = async (request, response) => {
        let jobAcquired = false;
        const origin = request.headers.origin;
        if (origin && config.allowedOrigins.has(origin)) {
            response.setHeader("access-control-allow-origin", origin);
            response.setHeader("vary", "Origin");
            response.setHeader("access-control-allow-headers", "authorization,content-type,x-organization-id");
            response.setHeader("access-control-allow-methods", "POST,OPTIONS");
        }
        if (request.method === "OPTIONS") {
            response.writeHead(origin && config.allowedOrigins.has(origin) ? 204 : 403);
            response.end();
            return;
        }
        if (request.url === "/healthz" || request.url === "/readyz") {
            json(response, 200, { status: "ok", active_jobs: activeJobs });
            return;
        }
        if (request.method !== "POST" || request.url !== "/v1/voice/transcode") {
            json(response, 404, { error: "not found" });
            return;
        }
        if (origin && !config.allowedOrigins.has(origin)) {
            json(response, 403, { error: "origin not allowed" });
            return;
        }
        const authorization = request.headers.authorization;
        const organizationId = request.headers["x-organization-id"];
        const contentType = request.headers["content-type"] ?? "";
        if (!authorization?.startsWith("Bearer ") ||
            typeof organizationId !== "string") {
            json(response, 401, { error: "authentication required" });
            return;
        }
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(organizationId)) {
            json(response, 400, { error: "invalid organization" });
            return;
        }
        if (!contentType.startsWith("audio/")) {
            json(response, 415, { error: "audio recording required" });
            return;
        }
        try {
            await dependencies.authorize(config, authorization.slice(7), organizationId);
            const input = await readBody(request, config.maxInputBytes);
            if (input.length === 0)
                throw new Error("empty recording");
            if (activeJobs >= config.maxConcurrentJobs) {
                response.setHeader("retry-after", "2");
                json(response, 503, { error: "converter busy" });
                return;
            }
            activeJobs += 1;
            jobAcquired = true;
            const result = await dependencies.transcode(config, input);
            response.writeHead(200, {
                "content-type": "audio/ogg; codecs=opus",
                "content-length": String(result.audio.length),
                "x-audio-duration-seconds": result.durationSeconds.toFixed(3),
                "cache-control": "no-store",
            });
            response.end(result.audio);
        }
        catch (error) {
            const message = error instanceof Error ? error.message : "voice conversion failed";
            const status = message === "unauthorized"
                ? 403
                : message.includes("limit") || message.includes("exceeds")
                    ? 413
                    : 422;
            json(response, status, { error: message });
        }
        finally {
            if (jobAcquired)
                activeJobs -= 1;
        }
    };
    const server = createServer();
    server.on("request", (request, response) => {
        void handleRequest(request, response);
    });
    return server;
}
//# sourceMappingURL=server.js.map