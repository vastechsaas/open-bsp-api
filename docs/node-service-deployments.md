# Node service deployment standard

Each Node service has its own `compose.yaml`, `.env`, container and local port.
Manage one service from its own directory; there is no combined stack that can
accidentally restart the other service. Application code, authentication, tenant
configuration and Nginx routes are unchanged by this deployment standard.

| Service      | Server directory under `/opt/openbsp/open-bsp-api` | Container                  | Local port       |
| ------------ | -------------------------------------------------- | -------------------------- | ---------------- |
| Queue worker | `services/chatbot-integration-worker`              | `openbsp-chatbot-worker`   | `127.0.0.1:8080` |
| Voice API    | `services/voice-transcoding-service`               | `openbsp-voice-transcoder` | `127.0.0.1:8090` |

Both definitions use `unless-stopped`, a 20-second stop grace period and
rotating Docker logs (five files of 10 MB each). Their images supply the
non-root runtime and `/readyz` health check. Voice explicitly retains the
existing `bridge` network; the worker retains its existing Compose network. Each
`.env` remains outside source control. Do not display it or paste a resolved
Compose config into tickets or chat: resolved configuration can include
credentials.

## Normal operations

Run these from the relevant service directory; use `sudo` on this instance:

```bash
sudo docker compose config --quiet
sudo docker compose up -d --no-build --pull never --wait --wait-timeout 60
sudo docker compose ps
sudo docker compose logs --tail 50
sudo docker compose restart
sudo docker compose stop
```

`restart` restarts the existing container; it does not apply changed environment
variables, Compose settings or a new image. Use `up` to apply those changes.
`config --quiet` validates without printing secrets. `stop` deliberately stops
that service; it then remains stopped until explicitly started.

For an intentional code release, test and build the reviewed version first,
record its image ID and retain the previous image. Then use `up` and check
health. Do not run `up --build` in an old server checkout or silently pull an
image while adopting an existing service. Initial adoption uses the exact
running image.

These definitions retain the current `latest` image names for compatibility;
they do not introduce a release-tagging or automated deployment system.

## Adopting the existing voice container

This is a deployment-only change on `51.170.85.38`. It requires one brief voice
restart. Do not restart the worker or change its queue bindings.

1. Validate the Compose file against the real `.env` using `config --quiet`.
   Confirm the `.env` values match the running voice container without printing
   them. Abort if there is drift, an unexpected mount, or an image-ID mismatch.
2. Create a root-only backup directory (mode `700`) outside the Git checkout.
   Save the container inspection, image ID, `.env` and relevant deployment files
   there with mode `600`. Container inspection includes secrets.
3. Confirm the current voice service is healthy and has zero active jobs. Keep
   the queue worker's container ID and start time for comparison.
4. Stop the voice container with a 20-second grace period. Retain it under a
   unique rollback name using `docker rename`; do not delete it or its image.
5. Start the Compose service using the `up --no-build --pull never --wait`
   command above. Do not use `--remove-orphans`.
6. Verify the exact image ID, configuration parity, loopback-only port, restart
   policy, `/healthz`, `/readyz` and the public HTTPS health endpoint. Check
   that the worker's container ID and start time are unchanged.

No application code, CORS origins, Supabase connection or credentials should
change. A successful health check is not a real authenticated audio-conversion
test; test a voice recording in Chat Center separately.

## Rollback

If adoption fails, stop and remove only the newly created Compose voice
container. Do not remove its retained predecessor or use broad cleanup commands.
Restore the retained container's original name with `docker rename` and start
it. Check local and public health again. Keep its original image available.

The retained predecessor is intentionally stopped. Do not start it while the
Compose replacement is running, because both use port `8090`. Keep the backup
path and predecessor name in the deployment record. No automatic pruning is part
of this procedure.

## New services

Use the same per-service layout and commands, but choose a unique container
name, local port and environment file. Reuse tooling and deployment patterns,
not another service's credentials, tenant mappings or queue. Add a distinct
Nginx/HTTPS route only if the new service needs public access. Review capacity,
resource limits and readiness requirements for that particular workload before
deploying it; these are separate from this existing-service adoption.
