---
name: bundle-path-per-ruby-build
description: >-
  MUST be used when a bundled gem fails to load with "linked to incompatible
  .../libruby" under the project Ruby, or when setting BUNDLE_PATH (runner
  env, shadowenv lisp) on a machine that carries more than one build of the
  same Ruby version (rbenv-built and the brew keg).
---

# One BUNDLE_PATH per Ruby build, not per Ruby version

Bundler namespaces `BUNDLE_PATH` by ABI (`ruby/4.0.0/`), so two builds of
the same version — rbenv's `~/.rbenv/versions/4.0.6` and the keg
`/opt/homebrew/Cellar/ruby@4.0.6` — share one gem tree while their native
extensions link `libruby` by absolute path. Whichever build compiled the
extension owns it; the other refuses to load it. Any `BUNDLE_PATH` that
outlives one shell must therefore be keyed by `RUBY_ROOT`, never a bare
`~/.bundle`.

Wrong — a machine-wide path, reused when the project Ruby flips from rbenv
to the keg (ADR-0012):

    BUNDLE_PATH=/Users/ai-agent/.bundle
    # json/ext/parser.bundle: linked to incompatible ~/.rbenv/.../libruby.4.0.dylib

Right — the path follows the interpreter that will load the extensions:

    BUNDLE_PATH="$HOME/.bundle/$(ruby -e 'print RbConfig::CONFIG["prefix"].tr("/", "_")')"

Root cause stays unfixed here: the runner user (plans#26) sets a global
`BUNDLE_PATH` because it cannot write the keg's `GEM_HOME`; dev#294 is the
structural answer. Until then, verify a change with a throwaway
`BUNDLE_PATH=/tmp/<something> dev test` rather than editing the runner's env.

learned-from: dev#385 (the Bundler 4 probe fix); first `rake test` under the
keg Ruby on the ai-agent runner failed on a json extension built by rbenv.
date: 2026-11-01
