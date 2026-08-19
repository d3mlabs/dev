---
name: ai-flow-gitlink-exclusion
description: >-
  MUST be used when sweeping a worktree that may contain nested checkouts
  (e.g. an .ai-flow directory) — commit sweeps like git add -A, or tools
  that walk the whole tree like srb tc.
---

# Exclude nested .ai-flow checkouts from repo-wide sweeps

A nested checkout inside the worktree (such as an `.ai-flow` runner
checkout) pollutes anything that sweeps the whole tree. To git it is a
gitlink: `git add -A` stages a bare mode-160000 entry — a broken
submodule pointer with no `.gitmodules` — and the commit ships it
silently. To sorbet it is extra source: `srb tc` over `--dir .` picks up
`.ai-flow/sorbet/rbi`, whose gem RBIs clash with the repo's own as
duplicate-definition errors. Stage explicitly or exclude the directory
from the sweep; pass an ignore to tree-walking tools.

Wrong:

```sh
git add -A && git commit -m "iterate on PR feedback"
# the commit now carries: .ai-flow (mode 160000)
srb tc   # duplicate-definition errors from .ai-flow/sorbet/rbi
```

Right:

```sh
git add -A -- ':!.ai-flow'
srb tc --ignore=/.ai-flow
# and check `git status --porcelain` — never stage an unexpected
# 160000 entry
```

learned-from: d3mlabs/dev#35 (stray `.ai-flow` gitlink committed by the
iteration job; removed by hand in 0631a2b); broadened in the
d3mlabs/dev#123 conflict pass (`dev tc` failed on `.ai-flow` RBI clashes).
date: 2026-08-19
