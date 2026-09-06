# Engineering Workflow v1 — Controlled Smoke Test

## Purpose

This file is the deliberate, harmless candidate change for issue #20, the
controlled end-to-end smoke test of Engineering Workflow v1.

It is a record of that run, not a product feature. Its purpose is to prove
that the framework components composed correctly on a real repository
change, not to document application behavior.

---

## Scope of the smoke test

The smoke run is limited to exactly one file:

- `docs/engineering-workflow-v1-smoke.md`

No `.claude/**` framework file, no `.github/**` workflow, and no
application or runtime file is touched during the run.

If a framework defect were discovered during the run, the run stops at the
appropriate workflow off-ramp instead of widening this candidate. Any such
defect is fixed through a separate, manually reviewed framework-maintenance
issue and a later, independent smoke attempt.

---

## Workflow capabilities exercised

The smoke run exercises the following Engineering Workflow v1 capabilities:

- launcher-driven creation of a dedicated issue worktree and branch, using
  the `<type>/<issue-number>-<short-description>` naming convention, with an
  explicit run ID;
- validation of the authoritative issue contract before implementation
  begins;
- a read-only planner role that produces an implementation plan without
  modifying repository files;
- an implementer whose file-tool writes are denied at write time only for
  `.claude/**` framework paths, Git metadata, and paths outside the
  repository;
- deterministic allowed-path candidate verification that catches any
  change outside the single allowed path for every other in-repo location;
- deterministic `VERIFY_WORKTREE` verification of the candidate before
  independent review;
- an independent reviewer operating in a fresh, read-only context, separate
  from the implementer;
- a maintainer Human Gate that must be explicitly settled before staging;
- `VERIFY_STAGED` proof that the exact staged candidate matches the
  reviewed candidate;
- commit, push, and pull-request creation performed strictly in that order,
  and only after the preceding gates pass.

---

## Human review and merge

Automatic merge is forbidden. The final merge decision always belongs to a
human maintainer.

The objective per-run evidence supporting that decision — Verification
Records, the independent review verdict, the reviewed candidate
fingerprint, the commit identity, and the pull request itself — lives in
the workflow's own Verification Records and in the pull request, not in
this file.
