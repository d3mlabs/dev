---
name: harness-env-scrub
description: >-
  MUST be used when spawning a child process that should resolve the
  project's own toolchain (bundle, gem, ruby), or when minting a
  machine-persistent artifact (symlink, cache entry) from a resolved path.
---

# Harness env never leaks into project children

dev often runs inside a harness (a sandboxed agent session, a CI runner)
whose environment carries toolchain overrides — `BUNDLE_PATH`,
`BUNDLE_APP_CONFIG`, `GEM_HOME`, `GEM_PATH`, `RUBYOPT`, `RUBYLIB` —
pointing into the harness's ephemeral cache, so a child that inherits
ENV resolves the harness's toolchain instead of the project's. Unset
those overrides explicitly in the child env (see
`GemSkillLinker::HARNESS_ENV_SCRUB`), and as the belt-and-suspenders
half, never mint a persistent artifact from a path under `Dir.tmpdir` —
a durable link to purgeable state silently dangles later.

Wrong:

```ruby
Open3.capture3({ "BUNDLE_GEMFILE" => gemfile.to_s },
  "shadowenv", "exec", "--", "bundle", "list", "--paths")
```

Right:

```ruby
Open3.capture3(HARNESS_ENV_SCRUB.merge("BUNDLE_GEMFILE" => gemfile.to_s),
  "shadowenv", "exec", "--", "bundle", "list", "--paths")
# ...and skip (with a warning) any resolved path under Dir.tmpdir.
```

learned-from: dev#89 — a sandboxed session minted gem-skill symlinks into
the Cursor sandbox cache; same failure family as ai-flow#38–#40 (runner
shell env leaking into spawned agents).
date: 2026-08-03
