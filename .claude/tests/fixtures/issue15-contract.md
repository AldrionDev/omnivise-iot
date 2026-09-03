## Problem / Context

The repository has a validated issue-driven engineering workflow, but its
safety-critical workflow decisions are currently expressed only in documentation.

The replacement architecture is Claude Code-native and must not rely on LLM
reasoning for deterministic concerns.

## Goal

Implement the small deterministic core used by the future Claude-native
engineering workflow.

## Scope

Create the deterministic workflow core under `.claude/`.

### `issue-contract.sh`

Supported marker forms:

```text
### Allowed Changed Paths

- path/to/file
- directory/**
```

and:

```text
Allowed Changed Paths:
- path/to/file
- directory/**
```

## Out of Scope

* Claude Code skills, subagents, hooks.
* `.claude/settings.json`.
* Git staging, commit, push, pull-request creation or merge.

## Acceptance Criteria

* [ ] All deterministic core scripts are implemented under `.claude/scripts/**`.
* [ ] Tests and fixtures are implemented under `.claude/tests/**`.
* [ ] No third-party test framework is required.

## Verification

Run the complete workflow-core test suite:

```text
bash .claude/tests/run.sh
```

## Definition of Done

* [ ] Implementation remains within the approved deterministic-core scope.
* [ ] Full deterministic test suite passes.
* [ ] `git diff --check` passes.
* [ ] `docker compose config --quiet` passes.

## Human Gates / Maintainer Decisions

None.

The architecture decisions relevant to this issue are already resolved:

* use the Claude-native Option B architecture;
* verification is deterministic rather than agent-driven;
* no Python orchestrator.

## Technical Notes / Constraints

This issue is implemented manually.

### Allowed Changed Paths

* `.claude/scripts/**`
* `.claude/tests/**`

### Protected Paths

* `.github/**`
* `AGENTS.md`
* `CLAUDE.md`
* `docs/**`
* `README.md`
* `backend/**`
* `frontend/**`
* `simulators/**`
* `docker-compose.yml`
* `mongo-init.js`
* `mongo-replica-init.js`

Do not modify files outside Allowed Changed Paths.

Use Bash plus existing local tooling only.
