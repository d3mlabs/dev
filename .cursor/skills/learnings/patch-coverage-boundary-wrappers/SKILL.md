---
name: patch-coverage-boundary-wrappers
description: >-
  MUST be used when adding an injectable boundary wrapper (an
  Executor-style shell-out, a --help-only builtin registration) or
  diagnosing a failing codecov/patch check: the patch gate targets 100%
  of added lines.
---

# Patch coverage includes the real boundary wrapper

The codecov/patch gate targets 100% of added lines, and the lines most
often missed are exactly the ones tests deliberately route around: the
real body of an injectable executor (every unit test injects a fake) and
the body of a builtin that exists mainly to surface in `dev --help`.
Give the real wrapper one test that runs a real subprocess, and execute
the builtin body once with a fake collaborator injected through its
owning class's constructor (never `any_instance` — a body reachable only
that way is missing its seam; d3mlabs/plans#37 restructures Runner's
builtins so every one has its own).

Wrong: ship `GhCloner` with tests that only ever inject
`RecordingCloneExecutor` — the real `Executor#system` line is the
patch's only miss and codecov/patch fails at 97.x% while every named
test passes.

Right: one test runs `Executor.new.system("echo", …)` with a real file
standing in for `$stderr` (plus a `system("false")` false-return case),
and one dispatch test drives the builtin body end to end with a fake
injected at the constructor (`fake.expects(:run).with([…])`), asserting
the argv reaches the collaborator.

learned-from: dev#107 (codecov/patch reported 97.61% vs the 100% target;
the two misses were the real gh executor body and the clone builtin's
registration block); dev#110 (an interim constructor-seam sweep,
superseded by the d3mlabs/plans#37 Runner layering).
date: 2026-08-15
