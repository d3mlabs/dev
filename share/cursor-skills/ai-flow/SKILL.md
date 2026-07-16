---
name: ai-flow
description: >-
  Sync Cursor plans with GitHub issues via the `dev plan` CLI. Use when the
  user mentions plans, plan files, GitHub issues as plans, canonizing/linking
  a plan, pulling or pushing a plan, loading an issue as a plan, or addressing
  plan feedback (e.g. "load issue 123 as a plan", "push this plan", "canonize
  this plan", "address the open feedback on this plan").
---

# ai-flow: Cursor plans ⇄ GitHub issues

The GitHub issue is the canonical plan. The local plan file is a transient
working copy at `.cursor/plans/gh-<issue-number>-<slug>.plan.md` (gitignored).
The `dev plan` CLI is the only correct way to sync the two — it enforces a
conflict guard so local content can never clobber newer remote edits.

## Verb mappings

| User intent | Action |
|---|---|
| "load issue 123 as a plan" / "open issue 123 as a plan" | `dev plan pull 123`, then open the file it reports (under `.cursor/plans/`) |
| "push this plan" / "sync this plan to GitHub" | `dev plan push` (add the file path if several plans are linked) |
| "canonize this plan" / "link this plan to an issue" | `dev plan link <file>` to create a new issue from it, or `dev plan link <n> <file>` to attach it to existing issue #n |
| "create a plan for X" (canonical from the start) | `dev plan new "X"`, then edit the created file |
| "is this plan in sync?" | `dev plan status` |
| "address the open feedback on this plan" | see below |
| org-wide / cross-repo plan (not tied to this repo) | add `--org` to `new`/`link`/`pull` — targets the configured org plans repo |

## Addressing open feedback

Open feedback lives as issue comments (often quote-anchored). To address it:

1. Read the plan file's `<!-- ai-flow … -->` header for the `issue:` reference
   (`owner/repo#n`).
2. Fetch the comments: `gh api repos/<owner>/<repo>/issues/<n>/comments --paginate`.
3. `dev plan pull <n> --merge` first if the plan is behind.
4. Apply the quoted feedback to the local plan file (a quote anchors the
   section it concerns), then `dev plan push`.
5. Report which comments were addressed and which were skipped (and why).

## Link format (GitHub is the backend)

Plan links use GitHub URL format everywhere — the local plan file included,
since its content becomes the issue body verbatim. Never use local filesystem
paths (`/Users/…`) in a plan.

- Files: `https://github.com/<owner>/<repo>/blob/HEAD/<path>` (`blob/HEAD`
  always points at the repo's default branch).
- Other plans: their issue URL (`https://github.com/<owner>/<repo>/issues/<n>`).
- When working locally, resolve a `blob/HEAD` link to the workspace checkout
  (`~/src/github.com/<owner>/<repo>/<path>`) and read the file there — do not
  fetch it from GitHub.
- If a plan contains a local path (e.g. from a cmd+L file reference), rewrite
  it to the formats above while editing.

## Conventions (do not violate)

- Linked plan files start with an `<!-- ai-flow -->` HTML comment header
  carrying `issue:` and `synced_at:`. **Never hand-edit `synced_at`** — it is
  the sync guard's record of the remote state.
- **Always sync through `dev plan`.** Never `gh issue edit` a plan issue
  directly: that bypasses the conflict guard and stales the merge base, which
  degrades future pulls from auto-merge to manual reconciliation.
- A plan file without the header is a local draft; nothing syncs until it is
  linked (`dev plan link`). Ask before canonizing a scratch draft.
- If `dev plan push` refuses because the remote changed, run
  `dev plan pull <n> --merge`, resolve any conflict markers in the file, then
  push again.
- The issue body ends with an `<!-- ai-flow:plan -->` marker; leave it to the
  tooling.
