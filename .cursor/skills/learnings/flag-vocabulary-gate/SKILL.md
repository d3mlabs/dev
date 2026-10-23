---
name: flag-vocabulary-gate
description: >-
  MUST be used when adding or renaming a flag on a dev builtin, adding a
  builtin whose args are another command's argv, or diagnosing "unknown
  flag … exit 2" for a flag the builtin's call clearly handles.
---

# Declared flags are the only flags a builtin ever sees

`Cli::FlagVocabulary` gates every dev-defined node (builtin or group)
before `call`: `-h`/`--help` anywhere among the args is rewritten to
`help <path>` by the Runner (GlobalDispatch declines such argv), any other
`-`-prefixed arg outside `Command#flags` raises `UnknownFlagError` (usage
on stderr, exit 2), and the first `--` is consumed. Builtins hand-parse
their args, so the gate is the one place that knows the vocabulary — a
flag the body reads but `flags` omits is rejected before the body runs.

Wrong — the body learns a flag, the declaration does not:

    def flags = ["--keep"]
    def call(args:, context:)
      dry_run = args.include?("--dry-run")   # dev cache gc --dry-run → exit 2

Right — declare it beside the constant the body reads; a composed command
inherits the vocabulary of the args it forwards:

    DRY_RUN_FLAG = "--dry-run"
    def flags = [KEEP_FLAG, DRY_RUN_FLAG]
    def flags = [NO_CACHE_FLAG, *@install_deps_command.flags]  # UpCommand

A builtin whose words are someone else's argv (`complete`) opts out with
`opaque_args? = true`, as the project-command shapes do — never by
declaring flags. Root cause: builtins have no option table to validate
against (dev#217); a declarative one would make `flags` derivable and
retire this learning.

learned-from: dev#217 (`dev plan new --help` created an issue titled
"help"; `flags` became the contract every builtin must keep current)
date: 2026-10-15
