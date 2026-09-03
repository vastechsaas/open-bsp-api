import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import type { AddressInfo } from "node:net";
import { createVoiceServer } from "../src/server.js";
import type { Config } from "../src/config.js";

const config: Config = {
  port: 1,
  supabaseUrl: "https://example.test",
  supabaseAnonKey: "anon",
  allowedOrigins: new Set(["https://app.test"]),
  ffmpegPath: "ffmpeg",
  ffprobePath: "ffprobe",
  maxInputBytes: 100,
  maxDurationSeconds: 600,
  maxConcurrentJobs: 2,
  conversionTimeoutMs: 1000,
};

async function withServer(run: (url: string) => Promise<void>): Promise<void> {
  const server = createVoiceServer(config, {
    authorize: async (_config, token, organization) => {
      if (token !== "good" || !organization) throw new Error("unauthorized");
    },
    transcode: async (_config, input) => ({
      audio: Buffer.concat([Buffer.from("OggS"), input]),
      durationSeconds: 1.25,
    }),
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    await run(`http://127.0.0.1:${(server.address() as AddressInfo).port}`);
  } finally {
    server.close();
  }
}

test("health endpoint is available", async () =>
  withServer(async (url) => {
    const response = await fetch(`${url}/healthz`);
    assert.equal(response.status, 200);
  }));

test("authorized audio is converted without persistence", async () =>
  withServer(async (url) => {
    const response = await fetch(`${url}/v1/voice/transcode`, {
      method: "POST",
      headers: {
        authorization: "Bearer good",
        "x-organization-id": "123e4567-e89b-12d3-a456-426614174000",
        "content-type": "audio/webm",
        origin: "https://app.test",
      },
      body: Buffer.from("voice"),
    });
    assert.equal(response.status, 200);
    assert.equal(
      response.headers.get("content-type"),
      "audio/ogg; codecs=opus",
    );
    assert.equal(
      Buffer.from(await response.arrayBuffer()).toString(),
      "OggSvoice",
    );
  }));

test("rejects unauthorized, invalid media, oversized bodies and origins", async () =>
  withServer(async (url) => {
    const base = {
      method: "POST",
      headers: {
        authorization: "Bearer bad",
        "x-organization-id": "123e4567-e89b-12d3-a456-426614174000",
        "content-type": "audio/webm",
        origin: "https://app.test",
      },
      body: Buffer.from("voice"),
    };
    assert.equal((await fetch(`${url}/v1/voice/transcode`, base)).status, 403);
    assert.equal(
      (
        await fetch(`${url}/v1/voice/transcode`, {
          ...base,
          headers: {
            ...base.headers,
            authorization: "Bearer good",
            "content-type": "text/plain",
          },
        })
      ).status,
      415,
    );
    assert.equal(
      (
        await fetch(`${url}/v1/voice/transcode`, {
          ...base,
          headers: { ...base.headers, authorization: "Bearer good" },
          body: Buffer.alloc(101),
        })
      ).status,
      413,
    );
    assert.equal(
      (
        await fetch(`${url}/v1/voice/transcode`, {
          ...base,
          headers: {
            ...base.headers,
            authorization: "Bearer good",
            origin: "https://evil.test",
          },
        })
      ).status,
      403,
    );
  }));
