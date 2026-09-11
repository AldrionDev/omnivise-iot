# OmniVise IoT

OmniVise IoT is a full-stack IoT monitoring platform that streams simulated sensor
telemetry from ingestion all the way to a live browser dashboard in real time.

It is both a working application — a Java backend, a React dashboard, a Java sensor
simulator, and a MongoDB replica set — and an end-to-end DevOps / platform-engineering
portfolio project. The application is deliberately small; the engineering investment
is in how it is built, verified, and delivered: pull-request CI on GitHub Actions, a
fail-closed Jenkins delivery pipeline keyed to the exact Git SHA, Terraform as the
authoritative Kubernetes deployment mutation path, a human approval gate, and
bounded non-destructive post-deploy verification against a real k3s cluster. It
implements production-oriented delivery practices and documents their limits.

## What it demonstrates

### Application features

- **Seeded device registry**: Five predefined monitored devices (two server racks,
  one UPS, one PDU, one CRAC unit) with device-specific channels and units.
- **Device/channel-scoped readings**: All sensor readings are keyed by `deviceId`
  and `channel`, with support for both numeric and string values (e.g., temperature
  in °C or door contact state "open"/"closed").
- **Real-time live updates**: Over a single WebSocket (`/ws/sensors`) with no polling.
  Typed message envelopes discriminate between reading and alert events.
- **History API**: Down-sampled time-series queries with 1-minute, 5-minute, and 1-hour
  buckets via MongoDB `$dateTrunc`. Max 1000 buckets per query; queries for invalid
  date ranges fail with a structured 400 response.
- **Threshold alerting**: Five seeded alerting rules with hysteresis (separate firing
  and clear thresholds). Firing/resolved state transitions are persisted and broadcast
  to clients. Optional outbound webhook for alert state changes.
- **Read-only alert rules API**: Clients can inspect the full rule set or query rules
  for a specific device; rule CRUD is not exposed.
- **React/TypeScript monitoring console**: Multi-view dashboard with overview, per-device
  detail charts, device list, and alerts view. Dark-first theme with persisted theme toggle.

### DevOps and delivery

- Full-stack real-time architecture: sensor simulator → MongoDB → Change Stream →
  backend → WebSocket → React UI.
- Javalin (Java 21) REST + WebSocket backend driven by MongoDB Change Streams.
- React 19 / Vite dashboard served by Nginx from one environment-independent image
  definition — backend upstream and DNS resolver are substituted at container
  startup, so the same build design runs under Compose and Kubernetes without baking
  environment-specific backend routing into the image.
- Standalone Java sensor simulator that writes directly to MongoDB.
- MongoDB 7 single-node replica set (`rs0`) — required for Change Streams — on a
  persistent volume.
- Containerised workloads with multi-stage Dockerfiles for all three components.
- OmniVise application deployment resources managed through Terraform (k3s); the
  namespace, ResourceQuota, and deployment RBAC are platform-owned.
- GitHub Actions as the pull-request CI gate.
- Jenkins as the post-merge homelab delivery pipeline.
- Exact 40-character Git SHA as the sole release identity.
- Write-once, fail-closed image publication (build once, reuse if present, stop on
  partial state).
- Saved Terraform plan → human approval → apply of that exact plan.
- Least-privilege Kubernetes deployer identity, with no admin fallback.
- Non-destructive post-deploy smoke: workload readiness, MongoDB writable-primary
  health, exact running image references, HTTP + API, a fresh WebSocket sensor event,
  and indirect ResourceQuota compatibility.

## Architecture

Runtime data path:

```
Sensor Simulator (Java)
    -> MongoDB rs0 PRIMARY   (omnivise_iot.sensor_readings)
    -> MongoDB Change Stream
    -> Backend (Javalin REST + WebSocket)
    -> WebSocket /ws/sensors
    -> Frontend (React SPA on Nginx)
    -> Browser
```

In Kubernetes, Traefik matches the canonical hostname and routes to the frontend
Service; the frontend Nginx reverse-proxies `/api/` and `/ws/` to the backend
Service.

Delivery pipeline:

```
GitHub pull request
    -> GitHub Actions CI   (backend + simulator + frontend + compose config)
    -> merge to main
    -> Jenkins             (post-merge delivery from main)
    -> exact Git SHA
    -> build images once -> homelab registry   (write-once, fail-closed)
    -> Terraform init / validate / fmt-check    (infra/homelab)
    -> saved plan -> human approval -> apply exact plan
    -> k3s (homelab)
    -> non-destructive post-deploy smoke
```

## Tech stack

| Category | Technologies |
| --- | --- |
| Backend | Java 21, Javalin 6, MongoDB Java sync driver, Jackson, dotenv-java, JUnit 5, Mockito |
| Frontend | React 19, Vite 7, Tailwind CSS 4, Vitest, ESLint; served by Nginx |
| Simulator | Java 17, MongoDB Java sync driver |
| Data | MongoDB 7, single-node replica set `rs0`, Change Streams, persistent volume |
| Infrastructure | Terraform (`hashicorp/kubernetes` provider), HCP Terraform remote state (Local execution), k3s, Traefik IngressRoute |
| CI/CD | GitHub Actions (pull-request CI), Jenkins (post-merge delivery from main) |
| Runtime | Docker, Docker Compose (local), Kubernetes / k3s (homelab) |

## CI/CD and release design

### GitHub Actions — pull-request CI gate

Runs on pull requests to `main` and on push to `main` (`.github/workflows/ci.yml`).
It verifies only; it performs no deployment, image publication, or infrastructure
change.

| Job | Commands |
| --- | --- |
| Backend | `mvn test`, `mvn package` (JDK 21) |
| Simulator | `mvn test`, `mvn package` (JDK 17) |
| Frontend | `npm ci`, `npm run lint`, `npm test`, `npm run build` (Node 22) |
| Compose | `docker compose config` |

### Jenkins — post-merge homelab delivery

Jenkins owns delivery (`Jenkinsfile`). `DEPLOY_TARGET` currently offers only
`homelab`.

- **Immutable release identity** — the exact 40-character Git SHA, resolved once and
  frozen. Backend, frontend, and simulator images are tagged
  `omnivise-iot/<component>:<git-sha>`. Mutable tags such as `latest` are rejected,
  including by Terraform variable validation.
- **Write-once publication** — the three images are one release set. All absent →
  build and push once; all present → reuse; any partial or ambiguous registry state →
  fail closed. After pushing, the pipeline re-probes the registry and requires a
  digest per image.
- **Terraform is the authoritative Kubernetes deployment mutation path** — `init` /
  `validate` / `fmt -check`, then a single saved plan (`terraform plan -out`). Jenkins
  never runs ad-hoc `kubectl apply`.
- **Human approval** — pre-approval evidence (release identity plus a read-only
  `terraform show` of the saved plan) is rendered, then a person approves applying
  that exact saved plan. There is no approval timeout and no re-plan after approval.
- **Non-destructive post-deploy smoke** — read-only checks against named resources
  only: workload readiness, including MongoDB writable-primary health proven through
  the StatefulSet readiness contract (`db.hello().isWritablePrimary`; no `kubectl
  exec` from the pipeline, no RBAC widening); exact running container image
  equality; `GET /` and
  `GET /api/sensors/latest`; a WebSocket subscription to `/ws/sensors` that must
  receive a fresh, structurally valid sensor event during the connection window
  (exercising the full simulator → MongoDB → Change Stream → backend → WebSocket
  path); and an indirect ResourceQuota compatibility check (the least-privilege
  identity cannot read the quota object and the RBAC is not widened).
- **Fail-closed throughout** — a malformed SHA, preflight failure, partial registry
  state, Terraform or state failure, readiness timeout, image mismatch, or smoke
  failure all stop the pipeline. There is no automatic rollback.

AWS / EKS delivery is **not implemented**. See [Current scope and future
direction](#current-scope-and-future-direction).

## Homelab deployment

The implemented deployment target is a k3s homelab cluster.

- `infra/homelab/` — the Terraform root (environment).
  `infra/modules/application/` — the reusable Kubernetes workload module.
- HCP Terraform workspace `omnivise-iot-k8s`, Local execution mode: HCP provides
  remote state and locking, while Terraform itself runs on the Jenkins host because
  the k3s API is LAN-only.
- Canonical hostname `omnivise-iot.homelab.home.arpa`, plain HTTP via the Traefik
  `web` entrypoint.
- MongoDB runs as a persistent single-node replica set (`rs0`) on a `local-path`
  PVC, initialised by a one-shot bootstrap Job.
- Terraform plan/apply runs as a project-scoped, least-privilege
  `omnivise-iot-deployer` service account — no cluster-admin, no admin kubeconfig
  fallback.

No LAN IPs or credentials are stored in the repository; runtime values are supplied
by the operator or the Jenkins platform outside Git.

## Verified delivery

The first complete Jenkins-driven homelab delivery was executed and verified end to
end. Evidence: [`docs/homelab-delivery-acceptance.md`](docs/homelab-delivery-acceptance.md).

Summary: pipeline result SUCCESS at Git SHA
`6ce2089a290d034b55a5047adbb9ce858ad5ff41`; the release images were built
and published write-once; the saved plan was approved and applied exactly
(`1 added, 3 changed, 0 destroyed`); and the non-destructive smoke passed, including a
fresh WebSocket sensor event received over the public route. The destructive MongoDB
pod-recreation persistence proof is deliberately out of scope for the automated
pipeline.

## Local development

Docker Compose is the current known-good local runtime.

```
docker compose up --build
```

| Service | URL |
| --- | --- |
| Frontend dashboard | http://localhost:3000 |
| Backend REST / WebSocket | http://localhost:8080 |
| mongo-express (local only) | http://localhost:8081 |

Ports are overridable via `docker-compose.yml` environment variables: `FRONTEND_PORT`
(default 3000), `BACKEND_PORT` (8080), `MONGO_PORT` (27017), and `MONGO_EXPRESS_PORT`
(8081). `mongo-express` is a local-development convenience and is not deployed to
shared environments.

Per-component checks:

```
cd backend    && mvn test && mvn package
cd simulators && mvn test && mvn package
cd frontend   && npm ci && npm run lint && npm test && npm run build
docker compose config
```

## REST API and WebSocket

### WebSocket

| Endpoint | Description |
| --- | --- |
| `WS /ws/sensors` | Subscribe to real-time reading and alert events (see below) |

**Message envelope** — all messages are typed JSON with a `kind` discriminator:

**Reading message:**
```json
{
  "kind": "reading",
  "payload": {
    "deviceId": "rack-a1",
    "channel": "intake_temp",
    "value": 21.4,
    "unit": "°C",
    "timestamp": "2026-09-10T08:00:00Z"
  }
}
```

**Alert message:**
```json
{
  "kind": "alert",
  "payload": {
    "id": "66f2a1b3c4d5e6f7a8b9c0d1",
    "ruleId": "rack-intake-temp-high",
    "deviceId": "rack-a1",
    "channel": "intake_temp",
    "severity": "warning",
    "state": "firing",
    "triggeredValue": 31.2,
    "lastValue": 31.2,
    "startedAt": "2026-09-10T08:15:00Z",
    "resolvedAt": null
  }
}
```

### REST Endpoints

| Method | Path | Query Parameters | Description |
| --- | --- | --- | --- |
| GET | `/` | - | API info (message + version) |
| GET | `/health` | - | Health check |
| GET | `/api/devices` | - | List all seeded devices with channels and units |
| GET | `/api/devices/{deviceId}` | - | Get a single device by ID |
| GET | `/api/sensors/latest` | `deviceId`, `channel`, `limit` (1–500, default 50) | Latest readings, newest first; optional device/channel filters |
| GET | `/api/sensors/history` | **required:** `deviceId`, `channel`, `from`, `to`, `bucket`; bucket values: `1m`, `5m`, `1h` | Down-sampled time-series. `from`/`to` must be ISO-8601 timestamps. Max 1000 buckets per query. |
| GET | `/api/alerts` | `state` (firing\|resolved), `severity` (warning\|critical), `deviceId`, `limit` (1–500, default 100) | All alert events matching the filters, newest first |
| GET | `/api/alerts/active` | `severity`, `deviceId`, `limit` | Convenience endpoint for `state=firing`; state cannot be overridden |
| GET | `/api/alerts/rules` | `deviceId` (optional; must be a known device if provided) | Seeded alert rules; without `deviceId`, returns all enabled rules; with `deviceId`, returns only rules applicable to that device. Unknown `deviceId` returns 400. |

## Frontend Routes

| Route | Description |
| --- | --- |
| `/` | Overview: dashboard with live readings and active alerts summary |
| `/devices` | Device list with live status indicators |
| `/devices/:deviceId` | Device detail: channel charts with history query, threshold rules |
| `/alerts` | Alerts view: firing and resolved alert events |

## Repository layout

```
backend/                     Javalin REST + WebSocket backend (Java 21), Change Stream listener
frontend/                    React 19 / Vite dashboard, Nginx config, Vitest tests
simulators/                  Standalone Java sensor simulator
docker-compose.yml           Local development runtime (MongoDB, backend, frontend, simulator, mongo-express)
infra/homelab/               Terraform root for the k3s homelab target
infra/modules/application/   Reusable Kubernetes workload module (MongoDB, backend, frontend, simulator, ingress)
docs/                        Architecture, delivery, deployment-smoke and acceptance documents
.github/workflows/           GitHub Actions pull-request CI
Jenkinsfile                  Post-merge homelab delivery pipeline
.claude/                     Issue-driven engineering workflow (agents, scripts, hooks)
```

The `.claude/` safety hooks are fail-closed only for the deterministic orchestrated
workflow (`OMNIVISE_WORKFLOW_MODE=orchestrator`); in ordinary interactive sessions
they are inert and safety rests on maintainer discipline. See
[`docs/development-workflow.md`](docs/development-workflow.md#safety-guard-hooks).

## Design principles / engineering decisions

- **Immutable release identity** — one 40-character Git SHA identifies the commit, all
  three images, the Terraform inputs, the approved plan, and the running workload.
- **Fail-closed delivery** — ambiguity stops the pipeline; it never guesses, repairs
  partial state, or broadens permissions.
- **Least privilege** — a project-scoped deployer identity; verification prefers a
  read-only mechanism over widening RBAC.
- **CI and CD are separate** — GitHub Actions gates pull requests, Jenkins delivers
  after merge, and neither duplicates the other.
- **Terraform owns Kubernetes deployment mutations** — no ad-hoc `kubectl apply`; the
  exact approved saved plan is the plan applied.
- **Human gate before deployment** — no apply without an explicit approval of a
  rendered, saved plan.
- **Bounded, non-destructive verification** — the routine smoke only reads; the
  destructive persistence proof stays a manual exercise.
- **No automatic rollback** — a failed apply is surfaced; the next operator-approved
  run reconciles from authoritative state.

## Documentation

- [`docs/architecture/delivery-architecture.md`](docs/architecture/delivery-architecture.md)
  — the accepted delivery architecture and the constraints that must stay stable.
- [`docs/homelab-deployment-smoke.md`](docs/homelab-deployment-smoke.md) — the
  reviewed manual deployment runbook the automation is derived from.
- [`docs/homelab-delivery-acceptance.md`](docs/homelab-delivery-acceptance.md) — the
  evidence record of the first Jenkins-driven delivery.

## Current scope and future direction

**Implemented**

- Full local runtime on Docker Compose.
- Seeded device registry with device/channel-scoped readings.
- History API with down-sampled time-series (1m/5m/1h buckets).
- Threshold alerting with hysteresis and firing/resolved lifecycle.
- Read-only alert rules API.
- Multi-view React/TypeScript monitoring dashboard.
- GitHub Actions pull-request CI.
- Jenkins post-merge delivery to k3s homelab target (`DEPLOY_TARGET=homelab`).

**Future direction (not implemented)**

Application features:
- Device CRUD operations (devices are currently seeded and read-only)
- Alert-rule CRUD (rules are currently seeded and read-only)
- Authentication and authorization
- History explorer UI (drill-down, range selection, export)
- Rack elevation / rack topology visualization

Observability:
- Prometheus metrics export
- Grafana dashboards
- OpenTelemetry instrumentation

Data and persistence:
- MongoDB time-series collections with TTL (currently using plain collections)

Infrastructure:
- AWS / EKS deployment target: `infra/aws/`, GHCR images, and `DEPLOY_TARGET=aws` / `both`
- Declared non-goals for AWS work: no Amazon ECR, no GitHub-to-AWS OIDC

This is architecture direction only. None of these future capabilities exist in the
repository today.
