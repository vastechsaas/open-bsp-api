import type { Config } from "./config.js";
export declare function verifyTools(config: Config): Promise<void>;
export declare function transcodeVoice(config: Config, input: Buffer): Promise<{
    audio: Buffer;
    durationSeconds: number;
}>;
