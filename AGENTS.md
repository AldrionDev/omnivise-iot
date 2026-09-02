# OmniVise IoT Project Instructions

## Project state

OmniVise IoT is a pet/portfolio project.

The current known-good runtime baseline is Docker Compose. Preserve working
Docker Compose behavior unless an issue explicitly changes it.

Current application components:

- `backend/`: Java/Javalin backend exposing REST, WebSocket, and health endpoints.
- `frontend/`: React/Vite frontend served by Nginx.
- `simulators/`: Java sensor data simulator writing directly to MongoDB.
- MongoDB 7 runs as a single-node replica set.
- MongoDB Change Streams are part of the live-data architecture and require
  the replica set.
- `docker-compose.yml` is the current local runtime definition.

Documentation may contain target-state or aspirational architecture that is not
implemented yet. Verify current-state claims against the actual repository before
relying on documentation.

If documentation conflicts with implementation, identify the conflict before
making changes.

`mongo-express` is a local-development tool and must not be deployed to shared,
homelab, or cloud environments unless explicitly requested.

## Issue-driven development

Development work is issue-driven.

When an issue number is provided, read the complete issue before planning or
implementing.

Treat these sections as the task contract:

- Problem / Context
- Goal
- Scope
- Out of Scope
- Acceptance Criteria
- Verification
- Definition of Done
- Technical Notes / Constraints

Do not implement work outside Scope.

Do not implement items explicitly listed as Out of Scope.

Acceptance Criteria define required observable behavior.

Verification defines how that behavior must be demonstrated.

Definition of Done defines all conditions that must be satisfied before the issue
may be considered complete.

If repository reality conflicts with the issue, identify the conflict before
making a potentially incorrect architectural or behavioral change.

## Change discipline

Use one issue per branch and one primary pull request per issue.

Preferred branch format:

`<type>/<issue-number>-<short-description>`

Examples:

- `fix/12-websocket-reconnect`
- `refactor/18-mongo-uri`
- `feat/31-k8s-mongodb`

Keep changes small, cohesive, and reviewable.

Do not include unrelated cleanup, refactoring, or speculative improvements.

Do not commit, push, merge, or create a pull request unless the current task
explicitly requests that action.

## Verification

Run checks relevant to every affected component.

### Backend

```bash
cd backend
mvn test
mvn package
````

### Simulator

```bash
cd simulators
mvn test
mvn package
```

### Frontend

```bash
cd frontend
npm ci
npm run lint
npm run build
```

### Repository

```bash
docker compose config
```

For changes affecting runtime integration, networking, configuration,
persistence, or component interaction, validate the affected behavior with
Docker Compose when the environment permits it.

Tests and executable checks are authoritative. An AI review does not replace
deterministic verification.

Do not claim an issue is complete while a relevant available check is failing.

If required verification cannot be performed, state exactly which check was not
run and why.

## Review expectations

Review findings use these severities:

### Critical

Security vulnerability, data-loss risk, severe correctness problem, broken
required behavior, or unsafe operational behavior.

Critical findings block completion.

### Major

Material bug, missing acceptance criterion, significant maintainability issue,
incorrect architecture, or missing required verification.

Major findings block completion.

### Minor

Non-blocking quality improvement with limited impact.

Minor findings do not automatically block completion unless the issue's
Definition of Done requires them to be resolved.

## Completion report

At the end of an implementation task report:

1. implementation summary
2. files changed
3. tests and checks run with results
4. Acceptance Criteria status
5. Definition of Done status
6. remaining risks or known limitations
7. intentionally deferred follow-up work