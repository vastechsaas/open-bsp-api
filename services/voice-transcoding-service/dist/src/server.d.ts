import { type Server } from "node:http";
import type { Config } from "./config.js";
import { authorizeTenant } from "./auth.js";
import { transcodeVoice } from "./transcoder.js";
export type Dependencies = {
    authorize: typeof authorizeTenant;
    transcode: typeof transcodeVoice;
};
export declare function createVoiceServer(config: Config, dependencies?: Dependencies): Server;
