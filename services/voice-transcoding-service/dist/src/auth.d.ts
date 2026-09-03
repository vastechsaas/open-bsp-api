import type { Config } from "./config.js";
export declare function authorizeTenant(config: Config, token: string, organizationId: string): Promise<void>;
