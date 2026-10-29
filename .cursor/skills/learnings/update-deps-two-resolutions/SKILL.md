---
name: update-deps-two-resolutions
description: >-
  MUST be used when adding a lock-writing policy (carry-over, pin
  rewrite, provenance) to dev deps update, or diagnosing a Gemfile ruby
  directive / .ruby-version that disagrees with the deps.lock ruby pin.
---

# dev deps update resolves twice — a lock policy applies to both

`Dev::Builtins::UpdateDepsCommand` runs `Resolver#resolve` twice: first
the interpreter declarations alone (`INTERPRETER_TYPES`), whose pins are
installed through brew *before* the lockers run so `bundle lock` solves
under the project Ruby (dev#76); then every declaration, whose pins the
lock writes. Anything that decides what the lock says about a pin
(`PinCarryover`, `EnvironmentImage.stamp`, any future rewrite) is a
policy of the lock being written, and the interpreter resolution is part
of that lock — the Ruby bundler ran under is the Ruby the Gemfile's
`ruby` directive and `.ruby-version` record.

Wrong — the policy after the second resolution only:

    interpreters = resolver.resolve(interpreter_declarations)   # today's 4.0.9
    install_interpreters!(project_root, interpreters)           # bundle lock under 4.0.9
    pins = carryover.apply(resolved: resolver.resolve(declarations), ...)  # lock keeps 4.0.6

Right — the same policy, same previous lock, on both resolutions:

    interpreters = carryover.apply(resolved: resolver.resolve(interpreter_declarations), ...).pins
    install_interpreters!(project_root, interpreters)           # the kept 4.0.6
    pins = carryover.apply(resolved: resolver.resolve(declarations), ...).pins

Read the previous lock once (`Lockfile#read_for_relock`) and hand it to
both calls; the test "installs the kept Ruby, not today's" in
`test/dev/builtins/update_deps_command_test.rb` guards the pairing.

learned-from: dev#355 (conservative brew relock — the first draft kept
the lock's Ruby while bundle lock ran under brew's newest)
date: 2026-10-29
