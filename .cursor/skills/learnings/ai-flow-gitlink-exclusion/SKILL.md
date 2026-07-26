---
name: ai-flow-gitlink-exclusion
description: >-
  MUST be used when committing swept changes (git add -A / git add .) in a
  worktree that may contain nested checkouts, e.g. an .ai-flow directory.
---

# Exclude .ai-flow gitlinks from commit sweeps

A nested checkout inside the worktree (such as an `.ai-flow` runner
checkout) is a gitlink to git: a sweep stages it as a bare mode-160000
entry — a broken submodule pointer with no `.gitmodules` — and the commit
ships it silently. Stage explicitly, or exclude known nested-checkout
directories from the sweep.

Wrong:

```sh
git add -A && git commit -m "iterate on PR feedback"
# the commit now carries: .ai-flow (mode 160000)
```

Right:

```sh
git add -A -- ':!.ai-flow'
# and check `git status --porcelain` — never stage an unexpected
# 160000 entry
```

learned-from: d3mlabs/dev#35 (stray `.ai-flow` gitlink committed by the
iteration job; removed by hand in 0631a2b)
date: 2026-07-25
