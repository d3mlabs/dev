---
name: command-runner-exec
description: >-
  MUST be used when sequencing work after cmd.execute in Dev::Runner#run,
  or when diagnosing a post-command step (like the installed stamp) that
  silently never happens.
---

# CommandRunner exec ends the dev process

`Dev::CommandRunner` runs project `run:` commands with `Kernel.exec` — the
dev process is replaced, so nothing after `cmd.execute` in
`Dev::Runner#run` executes for a yaml-declared command, nor for an
`OverriddenCommand` whose body is one. Post-execute steps only ever run
for fully in-process builtins; work that must always happen belongs
before the exec point.

Wrong — a follow-up step after execute, expecting it for every command:

    cmd.execute(args:, context:)
    stamp_installed(cmd_name, context.project_root) # skipped on exec

Right — do must-happen work before execute (which may never return), or
keep the command fully in-process:

    stamp_installed(cmd_name, context.project_root)
    cmd.execute(args:, context:)

Observed symptom: in a repo whose dev.yml defines `up:`, `dev up` exec's
into the project's up command and never reaches `stamp_installed`, so the
staleness gate keeps reporting "never installed" — fatal in a CI=true
shell. `dev install-deps` stays in-process and stamps. Check this before
suspecting the staleness digests themselves.

learned-from: dev#73 build pass (dev up never stamped; install-deps did)
date: 2026-08-02
