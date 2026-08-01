---
name: hook-points
description: >-
  MUST be used when adding side-work (links, syncs, renders) to dev up,
  dev install-deps, or dev plan — the rules hygiene rides by.
---

# dev hook points: hygiene rides, never blocks

`dev up` / `dev install-deps` (`Runner#install_locked_deps`) and every
`dev plan` invocation (`Plan::Accessor#run`) double as the refresh points
for agent-facing hygiene: shipped-skill links, gem-skill links, the
knowledge repo cache pull, and the org-invariants render + project link.
There is no separate setup step by design — riding existing commands is
what keeps the artifacts fresh without asking anything of the user.

Anything added to a hook point must obey both rules:

- **Hygiene must not block correctness.** The hook paths never raise —
  failures warn on stderr and the carrying command proceeds (see
  `GemSkillLinker#link_all`, `Learnings::Synchronizer#sync`,
  `SkillInstaller#install`).
- **Network on the hot path is bounded and ordered.** The cache pull runs
  inline *before* distribution (a hook never renders content it just
  found stale), capped by a ~2s timeout with a ~30s courtesy floor
  (`Learnings::Cache#refresh_bounded`, constants, not settings); on
  timeout or offline the current cache is served. The rest is idempotent,
  content-compared, millisecond-scale symlink and render checks.
  Unbounded blocking network belongs only behind an explicit command
  (`dev learnings sync` — the runner bootstrap contract's step).

origin: seeded by the dev#58 architecture pass
date: 2026-07-25
