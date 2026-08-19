---
name: scrub-guard-launch-env
description: >-
  MUST be used when BinDevTest's scrub-list guard ("the scrub list covers
  every key the running bundler exports") fails in a local dev test run.
---

# The bin/dev scrub-list guard asserts the launch env, not the code

The guard compares the test process's ENV against Bundler.original_env
and requires the launching bundler to have exported BUNDLE_GEMFILE — a
precondition about how the suite was started, not about the change under
test. Launching `dev test` from an agent harness shell can break that
precondition and fail the guard while the identical tree is green in CI
on the same machine. Before chasing it as a regression, diff the guard
and bin/dev against main and check CI: only a real scrub-list gap fails
in CI too.

Wrong:

```sh
# local `dev test` fails the guard → "my change broke scrubbing" →
# patch SHIM_UNSET_KEYS or the test until it passes locally
```

Right:

```sh
git diff origin/main -- bin/dev test/dev/bin_dev_test.rb  # identical?
gh run list --branch main --limit 3                       # CI green?
# then treat the local failure as launch-env noise, not a regression
```

learned-from: d3mlabs/dev#123 conflict pass (guard failed under the agent
shell; tree identical to main, CI green on the same runner machine).
date: 2026-08-19
