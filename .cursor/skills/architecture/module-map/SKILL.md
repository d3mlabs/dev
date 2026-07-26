---
name: module-map
description: >-
  MUST be used when deciding where new dev code lives or which module owns
  a concern — the ownership map of src/ and lib/.
---

# dev module map

- **`src/dev/`** — the typed (Sorbet) CLI core: Runner, command
  parser/registry, dev.yml config parsing, CLI UI, GlobalDispatch. Owns
  dispatch and execution, no feature logic.
- **`lib/dev/cd/`** — checkout jumping: RepoDiscovery walks the workspace
  root, Matcher ranks, ShellHook owns the RC function (a child process
  cannot cd its parent shell).
- **`lib/dev/plan/`** — Cursor plans ⇄ GitHub issues sync (the issue is
  canonical; a stored merge base guards against clobbering remote edits).
- **`lib/dev/deps/`** — dependency management. Layering is canonical in
  `.cursor/rules/separation-of-concerns.mdc`: Repository resolves,
  Integration installs, Lockfile serializes, the orchestrator
  coordinates — one class, one layer.
- **`lib/dev/knowledge/`** — org knowledge distribution: Cache (TTL git
  clone), Synchronizer (orchestration), InvariantsRenderer (the generated
  org-invariants.mdc).
- **`lib/dev/skill_installer.rb`** — the one symlink mechanism behind all
  three skill channels (shipped, org, gem); the gem channel's lockfile
  scan is `lib/dev/deps/gem_skill_linker.rb`.
- **`lib/dev/credentials.rb`** (+ `credential_accessor.rb`) — XDG-scoped
  credential storage behind `dev cred`.
- **`lib/shadowenv_*.rb`** — per-toolchain env provisioning written into
  `.shadowenv.d/` by project setup.
- **`share/cursor-skills/`** — skills dev ships user-globally (ai-flow,
  capture-learning).

origin: seeded by the dev#58 architecture pass
date: 2026-07-25
