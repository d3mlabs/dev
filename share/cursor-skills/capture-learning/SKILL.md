---
name: capture-learning
description: >-
  Capture, revise, promote, or retire learnings — lessons distilled from
  feedback and stored as an index line plus a detail skill. Use when the
  user says "remember this" / "make this a learning", asks to scan one or
  more repos for learnings, to promote a learning org-wide, or to retire
  one — or when you notice being corrected for the same thing twice.
---

# capture-learning: distill lessons into indexed learnings

A learning is one unit materialized two ways: an index line in the repo's
`.cursor/rules/learnings-index.mdc` (always-on awareness, ~15 tokens per
session) and a detail skill at `.cursor/skills/learnings/<slug>/SKILL.md`
(loaded on demand). This skill is the local-session twin of ai-flow's
`/learn` command — same rubrics, same output shape — for every form:
dictated, sweep, scan, promote, revise, retire.

## Distillation rubric (what qualifies)

Only lessons that generalize beyond the immediate diff or session become
learnings. Three kinds, one format:

- **coding practices** — style/API corrections that will recur,
- **architecture knowledge** — constraints and shapes of the system
  ("X must never call Y directly", "this subsystem owns that lifecycle"),
- **process rules** — e.g. "gitlink dirs must be excluded from sweeps".

Diff-local fixes (typos, renames, one-off bugs) are not learnings.

Before drafting, dedup: search the repo's learnings index and the org
tier (skills under `~/.cursor/skills/`, the generated
`.cursor/rules/org-invariants.mdc`) for an equivalent or conflicting
entry. Revising an existing learning always beats adding a duplicate, and
the same lesson already captured in a *different* repo is a promotion
signal — draft the promotion, not a third copy.

## Scope rubric (where it lands)

Ask: is this about *this repo's* code, or about *how we build software*?
Repo-specific lessons land in the current repo's index and skills.
Repo-agnostic lessons target the org knowledge repo (a PR there; the
merge is the rollout). Borderline calls default to repo-local — later
promotion is cheap, demoting a wrongly-global rule is confusing.

## Format

Index line, grouped into a `## <domain>` section of the index:

```markdown
- [domain/slug] One-sentence trigger. → .cursor/skills/learnings/<slug>/
```

Detail skill, hard cap ~40 lines: frontmatter `name` matching its folder
and an imperative `description` ("MUST be used when …"); the rule in two
sentences; one wrong/right pair; a `learned-from:` origin link; a
`date:`. Architecture digests follow the same shape under
`.cursor/skills/architecture/<topic>/`.

Caps: the index is soft-capped at ~50 entries — at the cap, propose a
retirement, a consolidation, or a glob-scoped sub-index split alongside
any addition. A learning outgrowing 40 lines graduates to a full skill
owned by the thing it documents (the rspock gem skill is the archetype).

## Forms

- **Dictated** ("remember this: …") — the human already distilled the
  lesson; format it, dedup, apply the scope rubric. No sweep.
- **Sweep** — distill a surface's feedback (a reviewed PR, an issue
  discussion, this session's corrections): what generalizes becomes a
  learning; the rest was already absorbed.
- **Scan** ("scan this repo / these checkouts for learnings") — survey
  the named checkouts' code and docs, draft per-repo; dedup makes
  re-scans cheap (unchanged areas draft nothing). Scans also seed or
  refresh the architecture section.
- **Promote `<slug>`** — move the detail skill to the org knowledge repo
  and drop the repo entry (the org tier now carries it); origin links
  ride along.
- **Revise / retire** — when evidence contradicts or stales an existing
  learning, stage an edit or removal, never a contradictory sibling. The
  index must be able to shrink or it becomes noise.

## Output shape (the human gate)

Learnings merge through review, never silently:

- **In Cursor plan mode:** stage the proposals as sections of the plan
  document — index line, skill body, target tier per learning — and
  iterate conversationally ("drop 3, merge 2 into 5, that's org-wide");
  switching to agent mode applies the agreed set. Preferred for scans.
- **Otherwise:** write the files and open a proposal PR on a dedicated
  branch (`ai/learn-<source>`), the body embedding the motivating
  evidence and a `learned-from: <source>` marker line. Never mix
  learnings into an unrelated code PR — separate PRs give independent
  merge and revert outcomes.
