---
name: pre-bundle-stdlib-chain
description: >-
  MUST be used when editing lib/dev/deps core files (deps.rb, config, dsl,
  tap, lockfile, fetcher, dependency_installer, dependency*), raising a
  typed: sigil, or adding a require "sorbet-runtime" anywhere under Dev.
---

# The pre-bundle chain is stdlib-only; sorbet-runtime loads once at the root

`require "dev/deps"` is loaded by bin/setup.rb, bin/test.rb, and consumer
bootstrap BEFORE the bundle exists, so that chain (deps.rb → config → dsl,
tap, cli_ui, lockfile, fetcher, dependency_installer, dependency*) must
stay stdlib-only: no sorbet-runtime, no `sig`, sigils capped at
`typed: true` (or `false` where Data.define blocks Sorbet). The rubocop
Sorbet/StrictSigil excludes document each holdout — a non-strict sigil
there is deliberate, not a CI gap. Everything else lives under the `Dev`
namespace and gets sorbet-runtime from the single early require in
src/dev.rb (every entry point requires "dev" first); the only
self-requiring exceptions are the deps hooks (loaded standalone by
consumer dependencies.rb via install-build-deps) and lib/rake_test_argv.rb
(loaded standalone by bin/test.rb).

Wrong:

```ruby
# lib/dev/deps/config.rb — breaks bin/setup.rb on a fresh machine:
require "sorbet-runtime"
```

Right:

```ruby
# typed: true (ceiling for the pre-bundle chain; no sigs, no new require)
```

learned-from: dev#140 review — eight "why not typed: strict / why did CI
not catch this" threads, all answered by this constraint; the same review
centralized sorbet-runtime into src/dev.rb.
date: 2026-09-04
