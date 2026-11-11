---
name: command-dispatch
description: >-
  MUST be used when adding a dev command or changing how bin/dev routes
  argv — global builtins vs project (dev.yml) commands, and the command tree.
---

# dev command dispatch: two roots, one tree

`bin/dev` (sh shim → Ruby) routes argv through two composition roots over
the same tree machinery, and rescues nothing itself:

1. **Global builtins** — `Dev::Cli::GlobalDispatch` runs first when argv's
   first token names a `Dev::Cli::GlobalCatalog` command (`cd`, `clone`,
   `config`, `cred`, `learnings`, `plan`), before any dev.yml lookup; each
   owns host- or workspace-global state (`Dev::Cli::WorkspaceRoot`).
2. **Everything else** — `Dev::Cli::Runner`, project-optional. With a dev.yml:
   yaml commands + project builtins + the global catalog; without one:
   `help`, `up`, `runner`, the catalog, else the refusal in `Runner#exit_for`.

Commands form a **tree** (dev#188) with `dev` as root. Sealed
`Dev::Cli::Command` (`lib/dev/cli/command.rb`): every shape has `children`;
`BuiltinCommand`, `ProjectCommand`, `OverriddenCommand` run something,
`CommandGroup` is "children and nothing to run" (`CommandGroup.root`).
`CommandRepository#resolve` walks argv from the root; a group with a
leftover token is not-found (top level included). A resolved group hits
`CommandExecutor`'s group arm (`GroupExecutor` → `UsagePrinter#print_node`,
the one usage view; `help <path>` prints the same). `--help`/`-h` route to
bare `dev`; the hidden `complete` builtin walks the same tree. The seams:

- A noun with verbs is a `CommandGroup` over one leaf class per verb
  (`deps` → `DepsPathCommand`; `plan` → `PlanNewCommand`…); accessors expose
  one public method per verb — never hand-roll `case args.first` dispatch.
  Global nouns register in `GlobalCatalog`, project builtins in the Runner.
- Project commands live in dev.yml, never in dev's core; `commands:` parse
  to the node's `children` (`CommandGroup` when no `run:`) and merge child
  by child with a same-named builtin in the repository.
- The `Dev::Ui` tier is chosen once in `bin/dev` and handed to **both** roots
  (`GlobalDispatch.new(ui:)`, `Runner.new(ui:)`); a root left on `NoUi`
  renders every leaf plain at a terminal (dev#575).
