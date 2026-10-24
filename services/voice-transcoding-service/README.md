# Voice transcoding service

Stateless Node.js/FFmpeg service for SCRUM-115. It authenticates the caller with
Supabase, verifies accepted tenant membership, converts a browser recording to
mono OGG/Opus, and returns the bytes. It never stores recordings; the Chat
Center uploads the result through the existing tenant-protected media path.

```powershell
npm ci
npm run validate
docker build -t openbsp-voice-transcoder .
docker compose up -d --no-build --pull never --wait --wait-timeout 60
```

Configure the variables in `.env.example`, expose the service through HTTPS, and
set the UI's `VITE_VOICE_TRANSCODER_URL` to its public base URL. Keep the
service behind a request-size-limited reverse proxy. `/healthz` and `/readyz`
are available for orchestration.

## Deployment

Use `compose.yaml` from this directory, with the existing `.env` file. The
service binds only to `127.0.0.1:8090`; Nginx provides public HTTPS. Compose
preserves the existing bridge networking and adds bounded log rotation. The
image supplies the non-root user, application command and readiness check.

Run `docker compose ps`, `docker compose logs --tail 50` and
`docker compose restart` from this directory. Prefix commands with `sudo` when
required by the host. Use `up`, not `restart`, after changing configuration.

See [the shared deployment guide](../../docs/node-service-deployments.md) for
the queue worker's equivalent commands, safe adoption and rollback. Do not
rebuild or pull a different image as part of adopting an existing container.
