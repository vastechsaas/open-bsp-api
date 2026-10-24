import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

const services = [
  { name: "voice-transcoder", port: 8090, path: "../compose.yaml" },
  {
    name: "chatbot-worker",
    port: 8080,
    path: "../../chatbot-integration-worker/compose.yaml",
  },
];

for (const service of services) {
  test(`${service.name} has a consistent private Compose deployment`, () => {
    const compose = read(service.path);
    assert.match(compose, new RegExp(`  ${service.name}:`));
    assert.match(
      compose,
      new RegExp(`container_name: openbsp-${service.name}`),
    );
    assert.match(compose, /build:\s+context: \./);
    assert.match(compose, /restart: unless-stopped/);
    assert.match(compose, /env_file:\s+- \.env/);
    assert.match(
      compose,
      new RegExp(`"127\\.0\\.0\\.1:${service.port}:${service.port}"`),
    );
    assert.doesNotMatch(compose, /0\.0\.0\.0|network_mode: host|privileged:/);
    assert.match(compose, /stop_grace_period: 20s/);
    assert.match(compose, /driver: json-file/);
    assert.match(compose, /max-size: "10m"/);
    assert.match(compose, /max-file: "5"/);
    assert.doesNotMatch(
      compose,
      /SUPABASE_.*KEY|CLOUDAMQP_URL|ALLOWED_ORIGINS/,
    );
    assert.doesNotMatch(compose, /command:|entrypoint:|user:|volumes:/);
  });
}

test("voice adoption keeps the current bridge network and image health check", () => {
  assert.match(read("../compose.yaml"), /network_mode: bridge/);
  for (
    const file of [
      "../Dockerfile",
      "../../chatbot-integration-worker/Dockerfile",
    ]
  ) {
    const dockerfile = read(file);
    assert.match(dockerfile, /USER node/);
    assert.match(dockerfile, /HEALTHCHECK.*--interval=15s/);
    assert.match(dockerfile, /\/readyz/);
  }
});

test("operations guide distinguishes deployment from restart and preserves rollback", () => {
  const guide = read("../../../docs/node-service-deployments.md");
  assert.match(guide, /docker compose up -d --no-build --pull never --wait/);
  assert.match(guide, /docker compose restart/);
  assert.match(guide, /does not apply/);
  assert.match(guide, /docker rename/);
  assert.match(guide, /do not restart the worker/i);
  assert.match(guide, /do not use.*--remove-orphans/i);
});
