import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

function composeConfig(database) {
  const env = { ...process.env };
  if (database === undefined) {
    delete env.MONGO_INITDB_DATABASE;
  } else {
    env.MONGO_INITDB_DATABASE = database;
  }
  delete env.COMPOSE_FILE;

  return JSON.parse(
    execFileSync(
      "docker",
      [
        "compose",
        "--env-file",
        "/dev/null",
        "-f",
        "docker-compose.yml",
        "config",
        "--format",
        "json",
      ],
      {
        cwd: projectRoot,
        env,
        encoding: "utf8",
      },
    ),
  );
}

function assertApplicationDatabase(config, expectedDatabase) {
  const services = config.services;

  assert.equal(services.mongodb.environment.MONGO_INITDB_DATABASE, expectedDatabase);
  assert.equal(services["mongo-seed"].environment.MONGO_INITDB_DATABASE, expectedDatabase);
  assert.equal(services.backend.environment.MONGO_DATABASE, expectedDatabase);
  assert.equal(services["sensor-simulator"].environment.MONGO_DATABASE, expectedDatabase);
  assert.equal(
    services["mongo-seed"].command[1],
    "mongodb://mongodb:27017/?replicaSet=rs0",
  );
}

test("default Compose contract selects omnivise_iot for every component", () => {
  assertApplicationDatabase(composeConfig(), "omnivise_iot");
});

test("non-default Compose contract selects one application database", () => {
  assertApplicationDatabase(composeConfig("omnivise_iot_test"), "omnivise_iot_test");
});

test("Compose preserves an explicitly empty selector for fail-closed validation", () => {
  assertApplicationDatabase(composeConfig(""), "");
});

test("Compose preserves a whitespace-only selector for fail-closed validation", () => {
  assertApplicationDatabase(composeConfig("   "), "   ");
});

test("seed script keeps registry, rules, and sequence bootstrap on its connection database", () => {
  const seedScript = readFileSync(new URL("../mongo-init.js", import.meta.url), "utf8");

  assert.doesNotMatch(seedScript, /omnivise_iot/);
  assert.match(seedScript, /process\.env\.MONGO_INITDB_DATABASE/);
  assert.match(seedScript, /databaseName\.trim\(\)\.length === 0/);
  assert.match(seedScript, /db = db\.getSiblingDB\(databaseName\)/);
  assert.match(seedScript, /db\.devices/);
  assert.match(seedScript, /db\.alert_rules/);
  assert.match(seedScript, /db\.alert_sequences/);
});
