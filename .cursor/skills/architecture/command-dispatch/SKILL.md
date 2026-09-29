---
name: command-dispatch
description: >-
  MUST be used when adding a dev command or changing how bin/dev routes
  argv — global builtins vs project (dev.yml) commands, and the command tree.
---

# dev command dispatch: two roots, one tree

`bin/dev` (sh shim → Ruby) routes argv through two composition roots
over the same tree machinery:

1. **Global builtins** — `Dev::GlobalDispatch` runs first, before any
   dev.yml lookup, serving `Dev::GlobalCatalog` (`cd`, `clone`, `config`,
   `cred`, `learnings`, `plan`) from anywhere. Each owns host- or
   workspace-global state (anchored per call via `Dev::WorkspaceRoot`).
2. **Everything else** — `Dev::Runner`, the project-optional root. With a
   dev.yml: yaml commands + project builtins + the global catalog (listed,
   so help and completion show one tree). Without one: `up`, `runner`, the
   global catalog; other lookups map to the no-dev.yml refusal in
   `Runner#exit_for`. `bin/dev` rescues nothing.

Commands form a **tree** (dev#188). Sealed `Dev::Command`
(`src/dev/command.rb`) has four shapes: `BuiltinCommand`, `ProjectCommand`,
`OverriddenCommand`, `CommandGroup` (children + optional own leaf).
`CommandRepository#resolve` walks argv (child → own run → usage);
`CommandService` swaps a runnable group for its own leaf before guard/stamp;
a pure group hits `CommandExecutor`'s group arm (`GroupExecutor` prints
usage). The hidden `complete` builtin walks the same catalog for the shell
completers in `Cd::HookInstaller`.

The seams:

- A noun with verbs is a `CommandGroup` over one leaf class per verb
  (`deps` → `DepsPathCommand`; `plan` → `PlanNewCommand`…); accessors expose
  one public method per verb — never hand-roll `case args.first` dispatch.
  Global nouns register in `GlobalCatalog`, project builtins in the Runner.
- Project commands live in dev.yml, never in dev's core; nested `commands:`
  parse to `ProjectCommandGroup` and merge child by child with a
  same-named builtin in the repository.
