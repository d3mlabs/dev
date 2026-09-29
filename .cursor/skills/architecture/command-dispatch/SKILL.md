---
name: command-dispatch
description: >-
  MUST be used when adding a dev command or changing how bin/dev routes
  argv — global builtins vs project (dev.yml) commands, and the command tree.
---

# dev command dispatch: two layers, one tree

`bin/dev` (sh shim → Ruby) puts `src/` and `lib/` on the load path, then
routes argv through two layers:

1. **Global builtins** — `Dev::GlobalDispatch` runs first, before any
   dev.yml lookup, so `cd`, `plan`, `cred`, `learnings` work anywhere.
   Each owns host- or workspace-global state, never project config.
2. **Everything else** — `Dev::Runner`, the project-optional composition
   root. With a dev.yml: the yaml commands plus the project builtins.
   Without one: `up` and `runner` only; other lookups map to the
   no-dev.yml refusal in `Runner#exit_for`. `bin/dev` rescues nothing.

Inside the Runner, commands form a **tree** (dev#188). Sealed
`Dev::Command` (`src/dev/command.rb`) has four shapes: `BuiltinCommand`,
`ProjectCommand`, `OverriddenCommand`, `CommandGroup` (children + optional
own leaf). `CommandRepository#resolve` walks argv (child → own run →
usage); `CommandService` swaps a runnable group for its own leaf before
guard/stamp; a pure group hits `CommandExecutor`'s group arm
(`GroupExecutor` prints usage).

The seams:

- A new global command joins `GlobalDispatch::GLOBAL_COMMANDS` with a
  `lib/dev/<name>/Accessor` as its only CLI surface.
- A builtin with subcommands is a `CommandGroup` in `Runner#build_builtins`
  over one leaf class per verb (`deps` → `DepsPathCommand`, `runner` →
  `RunnerRegisterCommand`/`RunnerStatusCommand`, `cache` → `CacheGcCommand`).
  Never hand-roll `case args.first` dispatch inside a builtin.
- Project commands live in dev.yml, never in dev's core; nested
  `commands:` parse to `ProjectCommandGroup` and merge child by child
  with a same-named builtin in the repository.
