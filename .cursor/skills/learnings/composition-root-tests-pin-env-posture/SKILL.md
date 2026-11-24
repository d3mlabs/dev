---
name: composition-root-tests-pin-env-posture
description: >-
  MUST be used when a test builds the real `Dev::Cli::Runner` over a
  checkout and runs a verb that is not `staleness_exempt?`, or when a
  Runner-level test is green on a workstation and red only in the CI job.
---

# Composition-root tests pin the postures the root reads from the host

`Dev::Cli::Runner` composes every builtin on the host's own answers:
`Dev::Deps.detect_env` (`CI=true` turns the staleness guard from a
warning into `StaleDependencyStateError`), `Dev::Platform`, the data
root, the container engine. A test that builds the real Runner inherits
those answers from the process running the suite, so a verb the guard
covers (`package`, `build`, `deploy`, any `run:` command) exits 1 in the
CI job over a checkout whose `deps.lock` was never installed there —
the same test passes on a workstation, where the guard only warns. The
test pins each posture it does not test, as
`test/dev/cli/host_rule_integration_test.rb#setup` pins the full set.

Wrong — a scenario that needs a lock in the checkout, left to inherit
the job's posture:

    (root / "deps.lock").write("ruby:\n  ruby:\n    version: 4.0.6\n")
    runner = build_runner(root:, ...)
    runner.run(["package", "ai-flow"])   # CI: "stale dependency state"

Right — the posture pinned to what the scenario assumes, with the why:

    # `package` runs under the staleness guard; the refusal under test
    # is the channel's, so the guard reads the workstation posture.
    Dev::Deps.stubs(:detect_env).returns("dev")
    runner.run(["package", "ai-flow"])

Only `help`, `complete`, `version` and the other `staleness_exempt?`
builtins are safe to run over a locked checkout without the pin.

learned-from: dev#707 (the dev#676 runner test refused by the guard in
CI, not by the channel); the same pin already in
host_rule_integration_test and environment_integration_test
date: 2026-11-24
