function positiveInteger(value, fallback, name) {
    const parsed = Number(value ?? fallback);
    if (!Number.isInteger(parsed) || parsed <= 0)
        throw new Error(`${name} must be a positive integer`);
    return parsed;
}
export function loadConfig(env = process.env) {
    if (!env.SUPABASE_URL)
        throw new Error("SUPABASE_URL is required");
    if (!env.SUPABASE_ANON_KEY)
        throw new Error("SUPABASE_ANON_KEY is required");
    const origins = (env.ALLOWED_ORIGINS ?? "http://localhost:5173")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean);
    return {
        port: positiveInteger(env.PORT, 8090, "PORT"),
        supabaseUrl: env.SUPABASE_URL.replace(/\/$/, ""),
        supabaseAnonKey: env.SUPABASE_ANON_KEY,
        allowedOrigins: new Set(origins),
        ffmpegPath: env.FFMPEG_PATH ?? "ffmpeg",
        ffprobePath: env.FFPROBE_PATH ?? "ffprobe",
        maxInputBytes: positiveInteger(env.MAX_INPUT_BYTES, 16_000_000, "MAX_INPUT_BYTES"),
        maxDurationSeconds: positiveInteger(env.MAX_DURATION_SECONDS, 600, "MAX_DURATION_SECONDS"),
        maxConcurrentJobs: positiveInteger(env.MAX_CONCURRENT_JOBS, 2, "MAX_CONCURRENT_JOBS"),
        conversionTimeoutMs: positiveInteger(env.CONVERSION_TIMEOUT_MS, 30_000, "CONVERSION_TIMEOUT_MS"),
    };
}
//# sourceMappingURL=config.js.map