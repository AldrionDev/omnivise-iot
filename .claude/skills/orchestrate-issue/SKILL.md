---
name: orchestrate-issue
description: Run one GitHub issue through Engineering Workflow v1 inside its launcher-created worktree — contract validation, planner, implementer, deterministic verification, fresh independent review, bounded correction loops, and the controlled Git lifecycle up to a pull request that a human must review and merge. Use only in an issue worktree created by .claude/scripts/launch-issue.sh.
---

# orchestrate-issue

You are the orchestrator for exactly one GitHub issue, running inside the issue
worktree that `.claude/scripts/launch-issue.sh` created before this session
started.

You coordinate. You do not decide mechanics. Every phase change, every counter,
every verification and every Git/GitHub action is performed by
`.claude/scripts/orchestrator.sh`, which owns the deterministic rules. Your job
is to run the right event at the right time, dispatch the right agent, and read
the result.

## Hard rules

1. **The state machine is not yours.** Never restate, re-derive or shortcut the
   phase graph. `orchestrator.sh` rejects any event that does not match the
   recorded phase; that rejection is authoritative.
2. **Never run a Git or GitHub command.** `git add`, `git commit`, `git push`,
   branch/worktree mutation and `gh` are denied for your session. Staging,
   committing, pushing and PR creation happen only through the orchestration
   events below.
3. **Never edit anything under `.claude/`.** The framework is read-only during
   issue execution, including in orchestrator mode.
4. **Never create a worktree or a branch.** They already exist. Worktree
   creation is a bootstrap step, not a workflow phase, and is never recorded in
   workflow state.
5. **Never override an agent's declared model or effort.** Dispatch `planner`,
   `implementer` and `reviewer` by name and let their definitions stand.
6. **No Agent Teams, no shared-context multi-agent cooperation.** One agent at a
   time, each with its own fresh context.
7. **Workflow state records phases, counters and objective identifiers only.**
   Never ask for your reasoning to be persisted anywhere.
8. **You never merge.** Human pull-request review and merge are mandatory and
   are outside this workflow.

## The authoritative sequence

Each step is one command. Run it, read its JSON result, then act.

```text
FETCH_ISSUE
  bash .claude/scripts/orchestrator.sh validate-contract   -> VALIDATE_ISSUE
  bash .claude/scripts/orchestrator.sh begin-plan          -> PLAN
      dispatch: planner
  bash .claude/scripts/orchestrator.sh begin-implement     -> IMPLEMENT
      dispatch: implementer
  bash .claude/scripts/orchestrator.sh verify-worktree     -> VERIFY_WORKTREE
  bash .claude/scripts/orchestrator.sh begin-review        -> REVIEW
      dispatch: reviewer (a NEW instance, every time)
  bash .claude/scripts/orchestrator.sh review-pass         -> RESOLVE_HUMAN_GATES
  bash .claude/scripts/orchestrator.sh gates-resolved      -> STAGE
  bash .claude/scripts/orchestrator.sh stage               (lifecycle: stage)
  bash .claude/scripts/orchestrator.sh verify-staged       -> VERIFY_STAGED
  bash .claude/scripts/orchestrator.sh commit              -> COMMIT   (lifecycle)
  bash .claude/scripts/orchestrator.sh push                -> PUSH     (lifecycle)
  bash .claude/scripts/orchestrator.sh create-pr           -> CREATE_PR
                                                           -> PR_READY_FOR_HUMAN_REVIEW
```

`bash .claude/scripts/orchestrator.sh status` prints the full recorded state at
any point. Use it after a resume, or whenever you are unsure which phase you are
in — never guess.

## Phase notes

**validate-contract.** The authoritative issue contract was stored as workflow
evidence by the launcher. This event revalidates it, checks it still matches the
recorded contract hash, and checks the Human Gates section. An invalid or
ambiguous contract fails into `CONTRACT_CLARIFICATION_REQUIRED`; an unresolved
gate fails into `HUMAN_DECISION_REQUIRED`. Do not read around the failure and
proceed.

**begin-plan / planner.** Dispatch the `planner` agent with the issue number and
the contract. The planner is read-only. Accept its plan yourself only when it
stays inside Scope and the Allowed Changed Paths; if the contract is ambiguous,
run `block --code CONTRACT_AMBIGUOUS` instead of guessing.

**begin-implement / implementer.** Dispatch the `implementer` agent with the
accepted plan. It has no shell and no Git capability by design. Never implement
the change yourself.

**verify-worktree.** Runs the deterministic verification suite over the complete
candidate and routes the outcome:

| deterministic outcome | routing |
| --- | --- |
| suite PASS | stays in `VERIFY_WORKTREE`; go to `begin-review` |
| `FAIL_IMPLEMENTATION` | `REPAIR_IMPLEMENTATION`, `impl_repair_attempts` +1 — re-dispatch `implementer`, then run `verify-worktree` again |
| repair budget exhausted | `MANUAL_REVIEW_REQUIRED` |
| `FAIL_ENVIRONMENT` / `TOOL_UNAVAILABLE` | `WAITING_ENVIRONMENT` |
| candidate mutated / indeterminate | `FAILED` |

**begin-review / reviewer.** Only reachable when the stored Verification Record
says PASS *for the current candidate fingerprint* and the index is empty. Always
dispatch a brand-new `reviewer`; never resume a previous reviewer and never let
implementer reasoning travel into the review. Each dispatch increments
`review_attempts`.

**Review outcomes.**

- No Critical or Major findings → `review-pass`. This captures the reviewed
  candidate manifest as workflow evidence (beside the state document, never as a
  repository file). Everything staged later is derived from that manifest.
- Critical or Major findings → `review-changes-required`. This enters `FIX` and
  consumes one of the two `review_correction_rounds`. Re-dispatch the
  `implementer` for the correction, then run `verify-worktree` again, then
  `begin-review` for a fresh reviewer.
- The reviewer asks only for evidence it did not have — no implementation change
  → `review-reassess`, then `reassess-complete`. This consumes **no** correction
  round. Use it only when nothing in the candidate changes.
- Correction budget exhausted → `MANUAL_REVIEW_REQUIRED`.

The implementation-repair budget and the review-correction budget are separate.
Never spend one to cover the other.

**gates-resolved → stage → verify-staged → commit → push → create-pr.** This
ordering is enforced, not advisory: staging happens only in `STAGE` and only
from the reviewed manifest, `verify-staged` proves the staged candidate is the
reviewed candidate, the commit is refused without that proof, the push is
refused without the commit, and the pull request is refused until the branch is
on the remote. Commit message, PR title and PR body are generated from recorded
state — you never supply them.

## Off-ramps

Fail closed. When you cannot proceed, run

```text
bash .claude/scripts/orchestrator.sh block --code <CODE>
```

with one of:

| code | off-ramp |
| --- | --- |
| `CONTRACT_INVALID`, `CONTRACT_AMBIGUOUS`, `CONTRACT_HASH_MISMATCH` | `CONTRACT_CLARIFICATION_REQUIRED` |
| `HUMAN_GATE_UNRESOLVED` | `HUMAN_DECISION_REQUIRED` |
| `ENVIRONMENT_FAILURE`, `TOOLING_UNAVAILABLE` | `WAITING_ENVIRONMENT` |
| `REVIEW_BLOCKING_FINDINGS_UNRESOLVED`, `REVIEW_CORRECTION_BUDGET_EXHAUSTED`, `IMPL_REPAIR_BUDGET_EXHAUSTED`, `STAGED_CANDIDATE_MISMATCH` | `MANUAL_REVIEW_REQUIRED` |
| `CANDIDATE_MUTATED`, `LIFECYCLE_FAILED` | `FAILED` |

Then stop and report to the maintainer. Do not attempt a workaround, and do not
try a different code to reach a phase you prefer.

A later session resumes an off-ramp with

```text
bash .claude/scripts/orchestrator.sh resume
```

which returns to the phase recorded when the off-ramp was entered — the only
resume target that exists.

## Reporting

When you reach `PR_READY_FOR_HUMAN_REVIEW`, report using the completion-report
structure in `AGENTS.md`, including the objective Verification Record fields.
State plainly that human review and merge are still required.
