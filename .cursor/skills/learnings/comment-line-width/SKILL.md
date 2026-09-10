---
name: comment-line-width
description: >-
  MUST be used when writing or reflowing code comments in this repo: wrap
  at the rubocop line width of 120, not the legacy ~80 columns that most
  existing comments still use.
---

# Comments wrap at 120, not the legacy 80

Rubocop (via rubocop-shopify) sets `Layout/LineLength` Max to 120, but most
comments predate the 80-to-120 expansion and are still wrapped at ~80 — and
no cop flags a too-narrow comment, so the legacy style silently propagates
by imitation. Fill new or edited comment blocks toward 120; the sweep of
the legacy comments is tracked in d3mlabs/dev#156.

Wrong:

```ruby
# Read as UTF-8 explicitly: the formulas have non-ASCII bytes (e.g. an
# em-dash in a comment), and when release.rb runs under a non-UTF-8 locale
# (such as a piped, login-less subshell) Ruby's default external encoding
# is US-ASCII.
```

Right:

```ruby
# Read as UTF-8 explicitly: the formulas have non-ASCII bytes (e.g. an em-dash in a comment), and when release.rb
# runs under a non-UTF-8 locale (such as a piped, login-less subshell) Ruby's default external encoding is US-ASCII.
```

learned-from: d3mlabs/dev#133 review — reviewer asked for the new
bin/release.rb comments to fill the 120 width instead of copying the
surrounding 80-column wrapping.
date: 2026-09-10
