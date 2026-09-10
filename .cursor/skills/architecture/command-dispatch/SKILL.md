---
name: command-dispatch
description: >-
  MUST be used when adding a dev command or changing how bin/dev routes
  argv — global builtins vs project (dev.yml) commands.
---

# dev command dispatch: two classes of command

`bin/dev` (sh shim → Ruby) puts `src/` and `lib/` on the load path, then
routes argv through two layers:

1. **Global builtins** — `Dev::GlobalDispatch`
   (`src/dev/global_dispatch.rb`) runs first, before any dev.yml lookup,
   so `cd`, `plan`, `cred`, and `learnings` work from any directory. Each
   owns host- or workspace-global state, never project config.
2. **Everything else** — builds `Dev::Runner` (`src/dev/runner.rb`), the
   project-optional composition root. With an enclosing dev.yml it runs
   the yaml-declared command plus the project builtins (`install-deps`,
   `deps`, `cache`, ...). Without one, the catalog is just `up` — a
   hybrid whose host half (converge + cd RC hook) always runs and whose
   project half needs the project (`ExecutionContext#project`, nil
   outside a project) — and any other lookup maps to the no-dev.yml
   refusal in `Runner#exit_for`. `bin/dev` itself rescues nothing.

The seams:

- A new global command joins `GlobalDispatch::GLOBAL_COMMANDS` and gets a
  feature module under `lib/dev/<name>/` whose `Accessor` is its only CLI
  surface (usage, arg parsing, clean failures) — see `Cd::Accessor`,
  `Plan::Accessor`, `Learnings::Accessor`.
- Project commands are declared in each repo's dev.yml, never hardcoded
  in dev's core.
- Workspace-global commands resolve their root as nearest dev.yml, else
  nearest `.git`, else cwd (`GlobalDispatch#workspace_root`).

origin: seeded by the dev#58 architecture pass
date: 2026-07-25
