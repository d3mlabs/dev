# Agents: plans, skills, learnings

dev carries three agent-facing features: plans as GitHub issues, skill
distribution, and org learnings. All work without a `dev.yml`.

## dev plan

The GitHub issue is the canonical plan; the local
`.cursor/plans/gh-<n>-<slug>.plan.md` is a working copy with an
`<!-- ai-flow … -->` header linking the two.

| Verb | What it does |
|---|---|
| `dev plan new "<title>" [--blank] [--org]` | Create an issue and a linked plan. Templated from the repo's `.github/ISSUE_TEMPLATE/plan.md` when present, else dev's bundled tech-design template; `--blank` scaffolds only the title. |
| `dev plan link <n> [<file>]` / `link <file>` | Attach a draft to an existing issue, or create an issue from it. |
| `dev plan pull <n> [--merge]` | Fetch the issue body; 3-way merge when both sides changed. |
| `dev plan push [<file>\|<n>]` | Update the issue body. Refuses to overwrite newer remote edits. |
| `dev plan status` | clean / ahead / behind / diverged, per linked plan. |
| `dev plan init` | Write or refresh the plan template mirror at `.github/ISSUE_TEMPLATE/plan.md`. Only a mirror still carrying dev's marker comment is overwritten; drop the marker to customize. |

`--org` targets the org plans repo (the `plans_repo` setting) instead of
the current repo.

For auto-push on save, add a Cursor `afterFileEdit` hook to
`.cursor/hooks.json` running `dev plan hook-after-edit`; it no-ops unless
the edited file is a linked plan. What happens to a plan once it is an
issue — `/ask`, `/edit`, `/split`, `/build` — is ai-flow's side:
[plan-lifecycle.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/plan-lifecycle.md).

## Skills

A skill is a `SKILL.md` directory an agent loads on demand. dev links
skills from three sources, refreshed on `dev up`, `dev deps install` and
`dev plan`:

| Source | Lands at | Scope |
|---|---|---|
| dev's own (`share/cursor-skills/*`) | `~/.cursor/skills/<name>` | machine |
| the org knowledge repo's `skills/*` | `~/.cursor/skills/<name>` | machine |
| gems in the project's lock that ship `skills/*/SKILL.md` | `.agents/skills/dev/gem/<gem>/<skill>` | project |

Package skills are keyed by integration and package, so two ecosystems
shipping a `tdd` skill both load. The links are repointed on a version
bump and pruned when a package leaves the lock. `.agents/skills/dev/`
ignores itself; everything else under `.agents/skills/` is the repo's own.

```bash
dev skills status [--json]   # every link, grouped by source, with package and version
dev skills sync              # re-link from what each source declares now
```

## Org learnings

A learning is a lesson distilled from feedback: an index line an agent
always sees, pointing at a detail skill it loads when relevant. Two tiers:

**Repo learnings** are committed: `.cursor/rules/learnings-index.mdc` (one
line per learning) and `.cursor/skills/learnings/<slug>/SKILL.md`. Every
checkout has them by construction. Capture goes through the
`capture-learning` skill in a Cursor session or ai-flow's `/learn`, both
landing as proposal PRs.

**Org learnings** live in the org knowledge repo (the `knowledge_repo`
setting). dev keeps a cache at `~/.local/share/dev/knowledge`, refreshes it
on the hooks above with a short timeout (serving the cache when offline),
links its skills machine-wide, and renders the index's invariants section
into each project as a symlink at `.cursor/rules/org-invariants.mdc`. One
refresh updates every project on the machine. Without the setting there is
no org sync.

```bash
dev learnings sync          # refresh now, blocking
dev learnings status        # what is cached, rendered, linked
dev learnings invariants    # print the invariants block (for prompt builders)
dev learnings init [--org | --gitignore]
```

`init` scaffolds an empty repo-tier index and writes dev's `.gitignore`
lines ([the list](gitignore.md)), or with `--org` the knowledge-repo
layout. An existing index is left untouched.

An agent-runner workflow runs `dev learnings sync` explicitly before
starting agent sessions, so they never start on stale invariants.

## What an adopting repo gitignores

The agent modules materialize three paths that must never be committed:
`.cursor/rules/org-invariants.mdc`, `.agents/skills/dev/` and
`.cursor/plans/`. They are part of dev's managed footprint, which `dev
learnings init --gitignore` writes and `dev learnings status` checks;
`dev skills status` and `dev plan status` each warn for their own path.
The full list, agent links and activation state together:
[What dev writes into a checkout](gitignore.md).

Tracked: `.cursor/rules/learnings-index.mdc`, `.cursor/skills/**`, and any
repo-own `.agents/skills/<name>/`.
