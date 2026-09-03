import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Config } from "./config.js";

function run(
  command: string,
  args: string[],
  timeoutMs: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr = (stderr + chunk).slice(-4000);
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("conversion timed out"));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stderr);
      else reject(new Error(`media conversion failed (${code ?? "unknown"})`));
    });
  });
}

function capture(
  command: string,
  args: string[],
  timeoutMs: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("media inspection timed out"));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout);
      else reject(new Error("invalid audio recording"));
    });
  });
}

export async function verifyTools(config: Config): Promise<void> {
  await run(config.ffmpegPath, ["-version"], 5000);
  await run(config.ffprobePath, ["-version"], 5000);
}

export async function transcodeVoice(
  config: Config,
  input: Buffer,
): Promise<{ audio: Buffer; durationSeconds: number }> {
  const directory = await mkdtemp(join(tmpdir(), "openbsp-voice-"));
  const source = join(directory, "source");
  const output = join(directory, "voice.ogg");
  try {
    await writeFile(source, input, { flag: "wx" });
    const probe = await capture(
      config.ffprobePath,
      [
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        source,
      ],
      config.conversionTimeoutMs,
    );
    const durationSeconds = Number.parseFloat(probe.trim());
    if (!Number.isFinite(durationSeconds) || durationSeconds <= 0)
      throw new Error("invalid audio recording");
    if (durationSeconds > config.maxDurationSeconds)
      throw new Error("recording duration exceeds limit");
    await run(
      config.ffmpegPath,
      [
        "-v",
        "error",
        "-i",
        source,
        "-vn",
        "-ac",
        "1",
        "-ar",
        "48000",
        "-c:a",
        "libopus",
        "-b:a",
        "48k",
        "-application",
        "voip",
        "-f",
        "ogg",
        output,
      ],
      config.conversionTimeoutMs,
    );
    const audio = await readFile(output);
    if (audio.length > 16_000_000)
      throw new Error("converted recording exceeds WhatsApp limit");
    return { audio, durationSeconds };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
