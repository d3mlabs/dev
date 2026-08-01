---
name: runner-shell-bundler-leak
description: >-
  MUST be used when dev/bundler commands in an ai-flow runner worktree fail
  with a Gemfile ruby-pin mismatch or resolve the wrong Ruby — the runner
  shell leaks its .ai-flow bundler environment into the project.
---

# Runner shells leak the .ai-flow bundler env

Shells spawned under the ai-flow runner carry the harness's bundler
activation — `RUBYOPT` preloading bundler/setup, `BUNDLE_GEMFILE` pointing
at `.ai-flow/Gemfile`, `GEM_HOME`/`GEM_PATH`/`RUBYLIB` — so `dev`/`bundle`
in the worktree resolves the harness's pins, not the project's (symptom:
`Bundler::RubyVersionMismatch` naming a Ruby the project never declared).
Strip the leaked variables first; `CI=true` is also set, so dev's
staleness guard errors (not warns) until `dev up` has stamped the checkout.

Wrong:

```sh
dev test   # inherits RUBYOPT/BUNDLE_GEMFILE → mismatch against .ai-flow's pin
```

Right:

```sh
env -u RUBYOPT -u BUNDLE_GEMFILE -u BUNDLER_SETUP -u BUNDLE_BIN_PATH \
    -u BUNDLER_VERSION -u GEM_HOME -u GEM_PATH -u GEM_ROOT -u RUBYLIB \
    -u RUBY_VERSION -u RUBY_ROOT -u RUBY_ENGINE -u __shadowenv_data \
    dev test
```

Sibling: `rbenv-libruby-rpath-hijack` — same ruby-pin-mismatch symptom,
different mechanism (Linux rpath, not env leakage).

learned-from: the dev#74 build pass — dev test failed under the runner env
until the shell was scrubbed.
date: 2026-08-01
