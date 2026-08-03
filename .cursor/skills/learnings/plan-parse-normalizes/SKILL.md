---
name: plan-parse-normalizes
description: >-
  MUST be used when changing how plan files are parsed or rendered
  (Dev::Plan::Content, Frontmatter, Header) or diagnosing a plan file
  that renders as raw text / loses its ai-flow header after a pull.
---

# Plan Content.parse is the normalization gate — mis-splits compound

Cursor rewrites plan files freely (frontmatter above the header, blank
lines after fences, a fresh empty frontmatter block stacked on top), so
`Dev::Plan::Content.parse` must recognize the layers in any of those
layouts and `render` restores canonical order (header, frontmatter,
body). There is no other repair point: every pull re-serializes what
parse produced, so anything parse lumps into the body is re-rendered
that way and the mangling compounds on each sync instead of healing —
that is how dev#60's double-frontmatter file grew.

Wrong — handle only the canonical layout and let the rest fall through:

    frontmatter, body = Frontmatter.split(remainder)
    # a second stacked block stays in body; next render ships it there

Right — peel leniently, collapse duplicates, stop at real content:

    frontmatter, body = split_stacked_frontmatter(remainder)
    # drops empty blocks above the content-carrying one; never consumes
    # a block after a non-empty one, so bodies starting with `---` YAML
    # are safe

When adding tolerance for a new Cursor layout, keep both invariants:
parse never destroys content (unclaimed text stays byte-exact in the
body), and render of a parsed mangled file must round-trip to canonical
form — assert that round-trip in the regression test.

learned-from: dev#60 (empty frontmatter stacked above the real one;
second layout bug in Content.parse after the misordered-header case)
date: 2026-08-03
