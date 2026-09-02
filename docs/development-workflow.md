# Development Workflow

## Purpose

This document defines the development workflow used for OmniVise IoT.

The workflow is issue-driven, reviewable, and human-approved. AI-assisted implementation and review may be used, but deterministic checks and human merge approval remain mandatory.

The goal is to keep changes small, auditable, reproducible, and safe while avoiding unnecessary process complexity.

---

## Core principles

Development work is driven by GitHub issues.

Each implementation issue must define:

- Problem / Context
- Goal
- Scope
- Out of Scope
- Acceptance Criteria
- Verification
- Definition of Done
- Technical Notes / Constraints, when applicable

The issue is the authoritative task contract.

Implementation must stay within the defined Scope.

Items explicitly listed as Out of Scope must not be implemented as part of the issue.

Acceptance Criteria define the observable behavior the implementation must provide.

Verification defines how the required behavior must be demonstrated.

Definition of Done defines the conditions that must all be satisfied before the issue may be considered complete.

---

## Roles

The workflow may use separate AI systems for implementation and review.

The intended initial setup is:

- OpenCode: primary planner and implementer
- Claude Code: independent reviewer
- deterministic tooling: tests, builds, linting, configuration validation, and other executable checks
- human maintainer: final pull request review and merge

The reviewer should be independent from the implementation context where practical.

The reviewer should receive:

- the GitHub issue
- the repository state
- the implementation diff
- the objective Verification Record

The reviewer should not rely on the implementer's reasoning or self-assessment as
evidence of correctness.

The reviewer may rely on the objective Verification Record as execution evidence
and may independently repeat any relevant checks.

---

## Standard issue workflow

For each implementation issue:

1. Read the complete GitHub issue.
2. Validate that the issue contains sufficient Scope, Acceptance Criteria, Verification, and Definition of Done.
3. Create a dedicated branch from the latest `main`.
4. Inspect the relevant repository files and documentation.
5. Produce a short technical implementation plan.
6. Implement only the defined issue Scope.
7. Run relevant `VERIFY_WORKTREE` deterministic checks and produce a Verification Record.
8. Perform an independent review using the issue, implementation diff, and Verification Record.
9. Fix blocking review findings when required.
10. Re-run `VERIFY_WORKTREE` and produce an updated Verification Record after implementation changes.
11. Repeat implementation correction and fresh review at most two times.
12. Resolve any required Human Gates / Maintainer Decisions.
13. Stage only the intended issue changes.
14. Run `VERIFY_STAGED` checks against the exact commit candidate.
15. Create a commit and pull request only when the required gates pass.
16. Human reviews the pull request.
17. Human performs the final merge.

---

## Branching

Use one primary issue per branch.

Branch names should follow:

`<type>/<issue-number>-<short-description>`

Examples:

```text
fix/12-websocket-reconnect
refactor/18-mongo-uri
feat/31-k8s-mongodb
chore/7-repository-hygiene
````

Common branch types:

* `fix`
* `feat`
* `refactor`
* `chore`
* `docs`
* `test`

Branches must be created from the latest intended base branch, normally `main`.

Long-lived milestone branches should be avoided.

---

## Scope control

Each branch and pull request should contain one cohesive change.

Do not include:

* unrelated refactoring
* opportunistic cleanup
* speculative features
* unrelated documentation changes
* architectural changes not required by the issue
* future milestone work

If unrelated work is discovered during implementation, document it as follow-up work and create a separate issue when appropriate.

If repository reality conflicts with the issue specification, stop before making a potentially incorrect architectural or behavioral decision.

The conflict must be documented and resolved explicitly.

---

## Planning

Before implementation, inspect the relevant code, configuration, tests, and documentation.

The implementation plan should be concise and include:

* affected components
* likely files to change
* implementation approach
* test strategy
* relevant risks
* assumptions that materially affect the solution

Planning should not expand the issue Scope.

Small and obvious changes may use a very short plan.

---

## Implementation

Implementation should:

* follow existing project architecture and conventions
* prefer the simplest maintainable solution
* preserve current behavior unless the issue explicitly changes it
* avoid unnecessary dependencies
* avoid premature abstractions
* include appropriate tests
* update documentation when runtime behavior, configuration, architecture, or operational behavior changes

Do not silently change:

* public APIs
* data models
* configuration contracts
* environment variable contracts
* deployment behavior

Such changes must be explicitly required or documented by the issue.

---

## Deterministic verification

Executable checks are authoritative.

AI review does not replace tests, builds, linting, or other deterministic checks.

Relevant checks may include:

### Backend

```bash
cd backend
mvn test
mvn package
```

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

Changes affecting runtime integration, networking, persistence, configuration, or component interaction should also be validated with Docker Compose when the environment permits it.

Additional checks should be added when new tooling or deployment targets are introduced.

A task must not be considered complete while a relevant available quality gate is failing.

If a required check cannot be executed, document:

* the exact check
* why it could not be run
* what risk remains because it was not run

---

## Verification Record

After implementation, deterministic verification must produce an objective
Verification Record.

The Verification Record is passed to the independent reviewer together with the
issue contract and implementation diff.

It must contain:

- exact commands executed
- command results or exit status
- relevant test counts where available
- checks that could not be run
- documented reasons for checks considered not applicable
- relevant deterministic observations such as Git state

The Verification Record is evidence.

It must not contain or substitute:

- implementer reasoning
- implementer self-review
- unsupported claims that the implementation is correct
- architecture justification unrelated to verification

The reviewer may independently repeat any relevant checks.

## Review

Implementation review should be independent from implementation where practical.

The reviewer evaluates:

* correctness
* issue Scope compliance
* Acceptance Criteria
* Definition of Done
* regressions
* security
* error handling
* maintainability
* test coverage
* operational risk
* unnecessary complexity

Review findings use the following severity levels.

### Critical

Examples:

* security vulnerability
* credential exposure
* data loss or corruption risk
* severe correctness failure
* required functionality is fundamentally broken
* unsafe deployment or operational behavior

Critical findings block pull request readiness.

### Major

Examples:

* material bug
* missing Acceptance Criterion
* incorrect architecture
* important regression
* insufficient error handling
* missing required verification
* significant maintainability problem
* unsafe configuration

Major findings block pull request readiness.

### Minor

Examples:

* small maintainability improvement
* naming issue
* limited duplication
* small documentation gap
* non-critical simplification opportunity

Minor findings do not automatically block pull request readiness unless the issue Definition of Done requires them to be resolved.

Minor findings should only be fixed automatically when the fix is:

* clear
* local
* low risk
* within the issue Scope

Otherwise they should be documented for human review or future work.

---

## Correction rounds

A correction round is consumed only when implementation files are changed in
response to review findings.

The following do not consume a correction round:

- providing missing deterministic verification evidence
- clarifying already documented verification results
- reviewer reassessment without implementation changes
- resolving a human gate
- correcting reviewer misunderstanding without changing implementation

After an implementation change triggered by review:

1. run relevant deterministic verification again;
2. produce an updated Verification Record;
3. perform a fresh independent review.

At most two implementation correction rounds are allowed.

If unresolved Critical or Major findings remain after the second implementation
correction round, automated progress must stop and the workflow must require
human review.

## Human gates

Some issue requirements cannot be resolved safely by an implementation or review
agent.

Examples include:

- confirming whether a historical credential was real or dummy
- approving a security or architecture trade-off
- authorizing infrastructure or account-level changes
- accepting an intentional compatibility break
- resolving requirements that depend on organizational policy

Such requirements must be marked as `HUMAN_GATE`.

An AI system must not infer or fabricate the decision.

If a required human gate is unresolved, the workflow state becomes:

`HUMAN_DECISION_REQUIRED`

The workflow may continue only after the maintainer records the decision.

The decision must be included in the pull request when it affects the issue
Definition of Done.

## Pull request readiness gates

A pull request is ready for creation only when:

* implementation is within the issue Scope
* required Acceptance Criteria are satisfied
* relevant deterministic verification has passed
* the issue-specific Definition of Done is satisfied or explicitly documented otherwise
* no unresolved Critical findings remain
* no unresolved Major findings remain
* remaining Minor findings are documented
* all required Human Gates / Maintainer Decisions are resolved
* relevant documentation is consistent with the implementation
* known risks and limitations are documented

A pull request must not be treated as automatically approved because AI review passed.

Human review remains mandatory.

---

## Definition of Done

An issue may be closed only when all applicable conditions are satisfied:

1. The implementation is complete.
2. The implementation stays within the defined Scope.
3. All Acceptance Criteria are satisfied.
4. Required Verification has completed successfully.
5. Relevant automated tests exist, or a clear reason is documented when tests are not applicable.
6. No relevant quality gate is failing.
7. No unresolved Critical review findings remain.
8. No unresolved Major review findings remain.
9. Documentation and configuration examples reflect the implemented behavior where affected.
10. Known limitations and intentionally deferred work are documented.
11. No unrelated changes are included in the pull request.
12. The pull request has been reviewed by a human.
13. The pull request has been merged by a human.

Issue-specific Definition of Done requirements may add additional conditions.

---

## Commit workflow

Commits should be small, cohesive, and meaningful.

Use Conventional Commit style where appropriate.

Examples:

```text
fix: make websocket endpoint deployment-independent
refactor: use unified MongoDB connection URI
feat: add MongoDB StatefulSet
chore: remove tracked runtime logs
```

Do not include unrelated changes in a commit.

During implementation, implementation agents must not independently:

* stage or unstage files
* create commits
* push branches
* merge branches
* create pull requests
* approve pull requests

These Git lifecycle actions belong to the human maintainer or the deterministic
orchestrator.

Reviewers must not modify the working tree or Git index.

---

## Pull request workflow

Each pull request should link its primary issue using:

```text
Closes #<issue-number>
```

The pull request should include:

* implementation summary
* files or areas changed
* verification commands and results
* checks that could not be run
* Acceptance Criteria status
* Definition of Done status
* review findings
* known risks
* intentionally deferred work

Human review is the final approval gate.

---

## AI-assisted workflow

The initial manual AI-assisted workflow is:

```text
GitHub Issue
     |
     v
OpenCode planning
     |
     v
OpenCode implementation
     |
     v
Deterministic verification
     |
     v
Claude Code independent review
     |
     +------ no blocking findings ------+
     |                                  |
     v                                  |
OpenCode correction                     |
     |                                  |
     v                                  |
Deterministic verification              |
     |                                  |
     v                                  |
Claude Code re-review                   |
     |                                  |
     +----------------------------------+
     |
     v
Pull Request
     |
     v
Human review
     |
     v
Human merge
```

This workflow should be exercised manually on several issues before automation is introduced.

The purpose is to validate the process, prompts, review quality, failure modes, and required gates before implementing an orchestrator.

---

## Refined workflow states

The manual workflow and future deterministic orchestrator should distinguish
implementation, review, human decisions, and Git lifecycle phases explicitly.

```text
FETCH_ISSUE
    ↓
VALIDATE_ISSUE
    ↓
CREATE_WORKTREE
    ↓
PLAN
    ↓
IMPLEMENT
    ↓
VERIFY_WORKTREE
    ↓
REVIEW
    │
    ├── Critical/Major findings
    │       ↓
    │      FIX
    │       ↓
    │   VERIFY_WORKTREE
    │       ↓
    │   FRESH REVIEW
    │
    ├── unresolved human gate
    │       ↓
    │   HUMAN_DECISION_REQUIRED
    │
    └── no blocking findings
            ↓
      RESOLVE_HUMAN_GATES
            ↓
          STAGE
            ↓
      VERIFY_STAGED
            ↓
          COMMIT
            ↓
           PUSH
            ↓
        CREATE_PR
            ↓
       HUMAN_REVIEW
            ↓
        HUMAN_MERGE
```

`VERIFY_WORKTREE` evaluates the implementation before Git staging.

Typical checks include:

- tests
- builds
- lint
- formatting
- type checks
- `docker compose config`
- runtime smoke tests
- `git diff --check`

`VERIFY_STAGED` evaluates the exact content intended for commit.

Typical checks include:

- `git diff --cached --check`
- `git status --short`
- `git diff --cached --stat`
- assertions whose meaning depends on Git index state
- confirmation that no unrelated files are staged

Git state must be determined by deterministic Git commands, not by reviewer or
implementer interpretation.

## Future orchestration

A future local orchestrator may automate the issue-to-pull-request workflow.

The orchestrator should be a deterministic state machine rather than an AI agent responsible for workflow control.

The canonical state model is defined in **Refined workflow states** above.
The orchestrator implementation should use that model rather than maintaining a
second independent state definition.

Terminal or exceptional states may additionally include:

```text
DONE
HUMAN_REVIEW_REQUIRED
FAILED
```

AI systems should only perform tasks requiring reasoning, such as:

* planning
* implementation
* code review
* scoped corrections

The orchestrator should control:

* state transitions
* command execution
* test result evaluation
* retry limits
* Git worktrees
* Git commits
* branch pushes
* pull request creation
* failure handling

Exit codes and machine-readable outputs should be preferred over AI interpretation for deterministic checks.

---

## Worktree isolation

The future automated workflow should use a dedicated Git worktree per issue.

Example:

```bash
git fetch origin

git worktree add \
  ../omnivise-iot-worktrees/12 \
  -b fix/12-websocket-reconnect \
  origin/main
```

Agents should operate only inside the assigned worktree.

This reduces risk to the primary working copy and allows failed automated runs to be discarded safely.

Parallel issue execution may be considered later, but the initial orchestrator should process one issue at a time.

---

## Human ownership

AI tools assist development but do not own repository decisions.

The human maintainer remains responsible for:

* issue prioritization
* milestone scope
* architectural decisions
* acceptance of intentional trade-offs
* final pull request review
* merge approval
* release decisions
* infrastructure and credential authorization

No automated workflow should merge directly to `main` without explicit future policy allowing it.