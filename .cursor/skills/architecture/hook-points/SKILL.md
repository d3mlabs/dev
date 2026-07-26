---
name: hook-points
description: >-
  MUST be used when adding side-work (links, syncs, renders) to dev up,
  dev install-deps, or dev plan — the rules hygiene rides by.
---

# dev hook points: hygiene rides, never blocks

`dev up` / `dev install-deps` (`Runner#install_locked_deps`) and every
`dev plan` invocation (`Plan::Accessor#run`) double as the refresh points
for agent-facing hygiene: shipped-skill links, gem-skill links, the org
knowledge TTL fetch, and the org-invariants render. There is no separate
setup step by design — riding existing commands is what keeps the
artifacts fresh without asking anything of the user.

Anything added to a hook point must obey both rules:

- **Hygiene must not block correctness.** The hook paths never raise —
  failures warn on stderr and the carrying command proceeds (see
  `GemSkillLinker#link_all`, `Knowledge::Synchronizer#sync`,
  `SkillInstaller#install`).
- **No network on the hot path.** Remote refreshes are TTL-gated and
  async (`Knowledge::Cache#refresh_async`); the synchronous work is
  idempotent, content-compared, millisecond-scale symlink and render
  checks. Blocking network belongs only behind an explicit command
  (`dev knowledge sync`).

origin: seeded by the dev#58 architecture pass
date: 2026-07-25
