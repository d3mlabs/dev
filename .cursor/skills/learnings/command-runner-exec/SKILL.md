---
name: command-runner-exec
description: >-
  MUST be used when adding a dev command, sequencing work after
  cmd.execute in Dev::Runner#run, or diagnosing a post-command step (like
  the installed stamp) that silently never happens.
---

# CommandRunner exec ends the dev process

`Dev::CommandRunner` runs project `run:` commands with `Kernel.exec` — the
dev process is replaced, so nothing after `cmd.execute` in
`Dev::Runner#run` executes for a yaml-declared command, nor for an
`OverriddenCommand` whose body is one. Post-execute steps only ever run
for fully in-process builtins — which makes this an input to command
placement: a builtin can carry post-steps, a `run:` command cannot.

Wrong — a follow-up step after execute, expecting it for every command:

    cmd.execute(args:, context:)
    stamp_installed(cmd_name, context.project_root) # skipped on exec

Also wrong: hoisting the step before execute, when it records an outcome
(the stamp means "provisioning *succeeded*" — stamping first marks a
failed `dev up` as installed). Success-contingent work needs the command
to run in-process: spawn-and-wait with the exit status propagated, not
exec-replace — that fix is dev#85. Only outcome-independent work may
move before the exec point.

Observed symptom: in a repo whose dev.yml defines `up:`, `dev up` exec's
into the project's up command and never reaches `stamp_installed`, so the
staleness gate keeps reporting "never installed" — fatal in a CI=true
shell. `dev install-deps` stays in-process and stamps. Check this before
suspecting the staleness digests themselves.

learned-from: dev#73 build pass (dev up never stamped; install-deps did);
the sequencing bug itself is dev#85
date: 2026-08-02
