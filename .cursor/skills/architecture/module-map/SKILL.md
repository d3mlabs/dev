---
name: module-map
description: >-
  MUST be used when deciding where new dev code lives or which module owns
  a concern — the ownership map of lib/ and the one layering rule.
---

# dev module map

One `lib/`; layers are namespaces pointing one way (ADR-0014): the shell
depends on features and vocabulary, never the reverse — no `Dev::Cli::*`
reference outside `lib/dev/cli/` (the `Dev/ShellReference` cop).

- **`lib/dev/cli/`** (`Dev::Cli`) — the shell: Runner, parsing, dev.yml
  loading and binding against the lock, dispatch, executors,
  `ExecutionContext`, `CommandRunner`, builtins, flags/usage, `UiImpl`.
  Owns parsing, dispatch and execution; no feature logic.
- **`lib/dev/ui.rb`** — `Dev::Ui`, the UI vocabulary features take as
  `ui:` (frame, spin, step, note, confirm), and `Dev::NoUi`, the plain tier.
- **`lib/dev/cd/`** — checkout jumping: RepoDiscovery walks the workspace
  root, Matcher ranks, ShellHook owns the RC function.
- **`lib/dev/plan/`** — Cursor plans ⇄ GitHub issues sync (the issue is
  canonical; a stored merge base guards against clobbering remote edits).
- **`lib/dev/deps/`** — dependency management; layering is canonical in
  `.cursor/rules/separation-of-concerns.mdc` (Repository resolves,
  Integration installs, Lockfile serializes, the orchestrator coordinates).
- **`lib/dev/learnings/`** — the learnings read path plus its scaffold:
  Cache (bounded clone/pull), Synchronizer, InvariantsRenderer (render +
  per-project symlink + the `dev learnings invariants` seam), Layout (both
  tiers' paths and templates; ai-flow mirrors them), Scaffolder (`init`).
- **`lib/dev/skill_installer.rb`** — the one symlink mechanism behind all
  three skill channels (shipped, org, gem; `deps/gem_skill_linker.rb`).
- **`lib/dev/credentials.rb`** (+ accessor) — XDG-scoped storage, `dev cred`.
- **`lib/shadowenv_*.rb`** — per-toolchain env provisioning written into
  `.shadowenv.d/` by project setup.
- **`share/cursor-skills/`** — skills dev ships user-globally (ai-flow,
  capture-learning).

origin: seeded by the dev#58 architecture pass
date: 2026-07-25
