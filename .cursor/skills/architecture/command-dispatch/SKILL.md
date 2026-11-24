---
name: command-dispatch
description: >-
  MUST be used when adding a dev command or changing how bin/dev routes
  argv — global builtins vs project (dev.yml) commands, and the command tree.
---

# dev command dispatch: two roots, one tree

`bin/dev` (sh shim → Ruby) routes argv through two composition roots over
the same tree machinery, and rescues nothing itself:
1. **Global builtins** — `Dev::Cli::GlobalDispatch` runs first when argv's first
   token names a `Dev::Cli::GlobalCatalog` command, before any dev.yml lookup;
   each owns host- or workspace-global state (`Dev::Cli::WorkspaceRoot`).
2. **Everything else** — `Dev::Cli::Runner`, project-optional. With a dev.yml:
   yaml commands + project builtins + the global catalog; without one:
   `help`, `up`, `runner`, the catalog, else the refusal in `Runner#exit_for`.

Commands are a **tree** (dev#188) under `dev`. Sealed `Dev::Cli::Command`
(`lib/dev/cli/command.rb`): every shape has `children`; `BuiltinCommand`,
`ProjectCommand`, `OverriddenCommand` run something, `CommandGroup` is children
and nothing to run (`CommandGroup.root`). `CommandRepository#resolve` walks argv
from the root; a group with a leftover token (the root too) is not-found; a
resolved group prints usage (`GroupExecutor` → `UsagePrinter#print_node`, the
one view; `help <path>`, `--help`/`-h` and the hidden `complete` too). Seams:

- A noun with verbs is a `CommandGroup` over one leaf class per verb
  (`deps` → `DepsPathCommand`; `plan` → `PlanNewCommand`…); accessors expose
  one public method per verb — never hand-roll `case args.first` dispatch.
  Global nouns register in `GlobalCatalog`, project builtins in the Runner.
- Verbs follow `docs/cli.md` "Command vocabulary": `status` reads, `check`
  exits, `install`/`up` resolve nothing, `update` moves; new verbs amend it.
- Project commands live in dev.yml, never in dev's core; `commands:` parse to
  `children` (`CommandGroup` when no `run:`), merged child by child with a
  same-named builtin in the repository.
- `bin/dev` picks the `Dev::Ui` tier once, handing `ui:` to **both** roots;
  a root left on `NoUi` renders every leaf plain at a terminal (dev#575).
- Before either root, the sh half hands off: inside dev's own checkout with
  its lock installed, the installed shim execs the checkout's `bin/dev`
  under its shadowenv (dev#689, `docs/cli.md`); no Ruby sees that argv.
