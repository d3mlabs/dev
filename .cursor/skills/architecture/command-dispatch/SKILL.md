---
name: command-dispatch
description: >-
  MUST be used when adding a dev command or changing how bin/dev routes
  argv — global builtins vs project (dev.yml) commands, and the command tree.
---

# dev command dispatch: two roots, one tree

`bin/dev` (sh shim → Ruby) routes argv through two composition roots
over the same tree machinery:

1. **Global builtins** — `Dev::GlobalDispatch` runs first when argv's
   first token names a `Dev::GlobalCatalog` command (`cd`, `clone`,
   `config`, `cred`, `learnings`, `plan`), before any dev.yml lookup. Each
   owns host- or workspace-global state (anchored via `Dev::WorkspaceRoot`).
2. **Everything else** — `Dev::Runner`, the project-optional root. With a
   dev.yml: yaml commands + project builtins + the global catalog. Without
   one: `help`, `up`, `runner`, the global catalog; other lookups map to
   the no-dev.yml refusal in `Runner#exit_for`. `bin/dev` rescues nothing.

Commands form a **tree** (dev#188) and `dev` is its root node. Sealed
`Dev::Command` (`src/dev/command.rb`): every shape has `children`;
`BuiltinCommand`, `ProjectCommand`, `OverriddenCommand` run something,
`CommandGroup` is "children and nothing to run" (`CommandGroup.root` for
the root). `CommandRepository#resolve` walks argv from the root; a group
with a leftover token is not-found (top level included). A resolved group
hits `CommandExecutor`'s group arm (`GroupExecutor` → `UsagePrinter#print_node`,
the one usage view; `help <path>` prints the same). `--help`/`-h` route to
bare `dev`. The hidden `complete` builtin walks the same tree.

The seams:

- A noun with verbs is a `CommandGroup` over one leaf class per verb
  (`deps` → `DepsPathCommand`; `plan` → `PlanNewCommand`…); accessors expose
  one public method per verb — never hand-roll `case args.first` dispatch.
  Global nouns register in `GlobalCatalog`, project builtins in the Runner.
- Project commands live in dev.yml, never in dev's core; `commands:` parse
  to the node's `children` (`CommandGroup` when no `run:`) and merge child
  by child with a same-named builtin in the repository.
