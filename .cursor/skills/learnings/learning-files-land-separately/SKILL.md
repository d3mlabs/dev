---
name: learning-files-land-separately
description: >-
  MUST be used when a code change or a test in an ai-flow build PR reads
  `.cursor/rules/learnings-index.mdc` or `.cursor/skills/learnings/**`,
  or when a PR's CI is red because an index line or skill it "added" is
  missing from the checkout.
---

# Learning files land through their own PR, never with the code

ai-flow splits every learning file — the index line and the detail
skill — out of the build commit into a separate proposal PR, so the code
PR's checkout never contains the learning it drafted, and the two merge
in either order. Code and tests in the build PR may lint what the index
says when it says it, but must never require a given line to be there.

Wrong — the build PR's lint guards against an empty match, which is
exactly what its own checkout has until the sibling learning PR merges:

```ruby
pointed_names = INDEX_FILE.read.scan(SHIPPED_POINTER).flatten
!pointed_names.empty?
pointed_names.all? { |name| shipped?(name) }
```

Right — the index lint passes vacuously; the pattern it relies on is
checked against literal lines, independent of index content:

```ruby
"→ skill: x (ships in dev's share/cursor-skills)".scan(SHIPPED_POINTER).flatten == ["x"]
INDEX_FILE.read.scan(SHIPPED_POINTER).flatten.all? { |name| shipped?(name) }
```

learned-from: d3mlabs/dev#620 (the index-line guard in
test/dev/shipped_skills_test.rb failed CI; the line it waited for was in
d3mlabs/dev#621)
date: 2026-11-18
