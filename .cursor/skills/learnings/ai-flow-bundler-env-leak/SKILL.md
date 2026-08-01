---
name: ai-flow-bundler-env-leak
description: >-
  MUST be used when a dev/ruby/bundle command in an ai-flow checkout fails
  with Bundler::RubyVersionMismatch or resolves the wrong Ruby — the runner
  shell leaks the nested .ai-flow checkout's bundler environment.
---

# ai-flow runner shells leak .ai-flow's bundler env

The ai-flow runner executes from inside the nested `.ai-flow` checkout, so
agent shells inherit `BUNDLE_GEMFILE` (pointing at .ai-flow/Gemfile),
`RUBYOPT` (preloading that Ruby's bundler/setup), `GEM_HOME`/`GEM_PATH`,
`RBENV_VERSION`, and `__shadowenv_data` — every Ruby invocation in the
outer repo then runs against the wrong Gemfile and fails its ruby pin.
Scrub those variables before any dev/ruby command; the mismatch is
environmental, never a project pin bug.

Wrong:

```sh
dev test   # Bundler::RubyVersionMismatch: your Ruby is X, Gemfile says Y
# ...so edit the Gemfile pin, or rebuild the project's gems
```

Right:

```sh
env -u BUNDLE_GEMFILE -u RUBYOPT -u BUNDLER_SETUP -u BUNDLE_BIN_PATH \
    -u BUNDLER_VERSION -u GEM_HOME -u GEM_PATH -u GEM_ROOT -u RUBY_ROOT \
    -u RUBY_VERSION -u RUBY_ENGINE -u RUBYLIB -u RBENV_VERSION \
    -u RBENV_DIR -u __shadowenv_data dev test
# if the staleness gate still nags after `dev up`, `dev install-deps`
# refreshes the per-machine install stamp
```

learned-from: dev#80 coverage pass — `dev test` failed the repo's 4.0.6
Gemfile against .ai-flow's 3.3.10 pin until the environment was scrubbed.
date: 2026-08-01
