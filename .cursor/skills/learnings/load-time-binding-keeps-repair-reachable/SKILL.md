---
name: load-time-binding-keeps-repair-reachable
description: >-
  MUST be used when moving a validation or binding from run time to load
  time in Dev::Runner (placements, targets, anything bound against the
  lock before CommandRepository#assemble), or when diagnosing a dev that
  refuses every command, `dev deps update` included, with a lock error.
---

# A load-time binding must leave the lock's repair command reachable

`Dev::Runner` is the composition root: anything bound against the lock
there — `PlacementBinder` since dev#409, targets with dev#192 — runs for
*every* invocation, `dev help` and `dev deps update` included. The lock
is also what some of those invocations exist to repair. If the binding
raises on a lock that cannot be read (`StaleDigestError`,
`RetiredBuildLockError`), the command that fixes the lock is itself
refused and the developer is locked out of the tool.

Wrong — bind at load and let the lock's errors bubble like any other:

    project_commands: PlacementBinder.new(images:).bind(manifest.commands)
    # StaleDigestError → exit(1) on `dev deps update` too

Right (dev#409) — two failure classes. *Wrong declaration*
(`UnknownImageError`, `AmbiguousEnvironmentImageError`) raises at load:
it is a dev.yml edit away. *Unreadable source* is rescued at the
composition root only, printed once on stderr, and the tree is left
unbound; builtins run, `dev help` renders without the column, and a
project command refuses at run with `ProjectCommand::UnboundPlacementError`
naming the repair. Consumers of the bound value (`CommandRunner`,
`UsagePrinter`) stay total: the runner refuses with the repair, the
printer omits the annotation.

    rescue EnvironmentImage::StaleDigestError, Deps::Lockfile::RetiredBuildLockError => e
      $stderr.puts "dev: #{e.message}"
      manifest.commands

learned-from: dev#409 build pass (binding placements at load would have
made `dev deps update` unreachable on a stale-digest lock); date: 2026-11-04
