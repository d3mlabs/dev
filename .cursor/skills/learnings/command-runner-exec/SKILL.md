---
name: command-runner-exec
description: >-
  MUST be used when adding a dev command, sequencing work after
  cmd.execute in Dev::Runner#run, or diagnosing a post-command step (like
  the installed stamp) that silently never happens.
---

# CommandRunner exec ends the dev process

`Dev::CommandRunner` runs project `run:` commands with `Kernel.exec` by
default — the dev process is replaced, so nothing after `cmd.execute` in
`Dev::Runner#run` executes for a yaml-declared command, nor for an
`OverriddenCommand` whose body is one. Must-happen work cannot sit after
a maybe-exec point: it lives in a fully in-process builtin, or the
command must run in CommandRunner's wait mode.

Wrong — a follow-up step after execute, expecting it for every command:

    cmd.execute(args:, context:)
    stamp_installed(cmd_name, context.project_root) # skipped on exec

Also wrong: hoisting the step before execute when it records an outcome
(the stamp means "provisioning *succeeded*" — stamping first marks a
failed `dev up` as installed). Only outcome-independent work may move
before the exec point.

Right (dev#85): Runner sets `wait: true` on ExecutionContext for
`STAMPING_COMMANDS` (`up`, `install-deps`); CommandRunner then runs the
child spawn-and-wait (`Kernel.system`) instead of exec-replace, raising
`CommandFailedError` with the child's exit status on failure, which
Runner turns into `Kernel.exit` — stamp only on success, exit code
preserved. Generic `run:` commands keep the exec tail-call (TTY/signal
passthrough, no double process tree). Diagnostic signature of a missing
wait: an exec-style provisioning command "succeeds" but the staleness
gate keeps reporting "never installed" — fatal in a CI=true shell.

learned-from: dev#73 build pass (dev up never stamped; install-deps
did); fixed by CommandRunner wait mode in dev#85
date: 2026-08-03
