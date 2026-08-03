---
name: harness-env-scrub
description: >-
  MUST be used when deciding where harness env scrubbing lives — a tool's
  entrypoint, an orchestrator's spawn seam, or a per-call shell-out — or
  when minting a machine-persistent artifact (symlink, cache entry) from a
  resolved path.
---

# Harness env is scrubbed at boundaries, not per spawn

Agent harnesses (sandboxed sessions, CI runners) carry toolchain overrides
— `BUNDLE_PATH`, `BUNDLE_APP_CONFIG`, `GEM_HOME`, `GEM_PATH`, `RUBYOPT`,
`RUBYLIB` — that make children resolve the harness's ephemeral toolchain
instead of the project's; scrub them at ownership boundaries: a tool that
owns its toolchain unsets foreign activation at its own entrypoint (dev's
`bin/dev` shell half), and an orchestrator bakes the scrub into its one
spawn seam (ai-flow's Executor) — never per call site, the discipline that
keeps failing because every new shell-out must remember it. Independently,
never mint a machine-persistent artifact from a path under `Dir.tmpdir` —
a durable link to purgeable state silently dangles, whatever produced it.

Wrong:

```ruby
# Per-call-site vigilance: ai-flow#38 fixed one spawn, ai-flow#44 hit
# the shell-out added later that forgot the scrub.
Open3.capture3(HARNESS_ENV_SCRUB.merge("BUNDLE_GEMFILE" => gemfile.to_s),
  "shadowenv", "exec", "--", "bundle", "list", "--paths")
```

Right:

```sh
# Tool entrypoint, before anything else boots — protects every caller:
unset BUNDLE_PATH BUNDLE_APP_CONFIG GEM_HOME GEM_PATH RUBYOPT RUBYLIB
```

```ruby
# ...and refuse persistent links to ephemeral paths, whatever the env:
next warn("skipping ephemeral #{path}") if path.start_with?(Dir.tmpdir)
```

learned-from: d3mlabs/dev#89 (sandboxed session minted gem-skill symlinks
into the sandbox cache); revised per d3mlabs/dev#91 review after boundary
fixes landed — entrypoint scrub d3mlabs/dev#94/#95, spawn-seam scrub
d3mlabs/ai-flow#46/#47, tmpdir guard d3mlabs/dev#90.
date: 2026-08-03
