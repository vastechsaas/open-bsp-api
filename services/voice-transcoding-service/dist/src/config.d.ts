export type Config = {
    port: number;
    supabaseUrl: string;
    supabaseAnonKey: string;
    allowedOrigins: Set<string>;
    ffmpegPath: string;
    ffprobePath: string;
    maxInputBytes: number;
    maxDurationSeconds: number;
    maxConcurrentJobs: number;
    conversionTimeoutMs: number;
};
export declare function loadConfig(env?: NodeJS.ProcessEnv): Config;
