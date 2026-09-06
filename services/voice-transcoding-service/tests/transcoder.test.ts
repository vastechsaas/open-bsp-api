import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import test from "node:test";
import type { Config } from "../src/config.js";
import { transcodeVoice } from "../src/transcoder.js";

const config: Config = {
  port: 1,
  supabaseUrl: "https://example.test",
  supabaseAnonKey: "anon",
  allowedOrigins: new Set(),
  ffmpegPath: "ffmpeg",
  ffprobePath: "ffprobe",
  maxInputBytes: 16_000_000,
  maxDurationSeconds: 600,
  maxConcurrentJobs: 2,
  conversionTimeoutMs: 1000,
};

test("converts browser WebM before reading duration from the generated OGG", async () => {
  const calls: string[] = [];
  const result = await transcodeVoice(
    config,
    Buffer.from("valid WebM stream without container duration metadata"),
    {
      run: async (_command, args) => {
        calls.push("convert");
        await writeFile(args.at(-1)!, Buffer.from("OggSconverted"));
        return "";
      },
      capture: async (_command, args) => {
        calls.push("probe");
        assert.match(args.at(-1)!, /voice\.ogg$/);
        return "7.25\n";
      },
    },
  );

  assert.deepEqual(calls, ["convert", "probe"]);
  assert.equal(result.durationSeconds, 7.25);
  assert.equal(result.audio.toString(), "OggSconverted");
});
