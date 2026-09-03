# Voice transcoding service

Stateless Node.js/FFmpeg service for SCRUM-115. It authenticates the caller with Supabase, verifies accepted tenant membership, converts a browser recording to mono OGG/Opus, and returns the bytes. It never stores recordings; the Chat Center uploads the result through the existing tenant-protected media path.

```powershell
npm ci
npm run validate
docker build -t openbsp-voice-transcoder .
```

Configure the variables in `.env.example`, expose the service through HTTPS, and set the UI's `VITE_VOICE_TRANSCODER_URL` to its public base URL. Keep the service behind a request-size-limited reverse proxy. `/healthz` and `/readyz` are available for orchestration.
