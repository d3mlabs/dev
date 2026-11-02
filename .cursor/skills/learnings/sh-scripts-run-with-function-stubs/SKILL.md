---
name: sh-scripts-run-with-function-stubs
description: >-
  MUST be used when testing a shipped shell script under bin/ (container
  provisioning, image bootstrap) beyond text matching — asserting what it
  did to the filesystem or the order of its tool calls.
---

# Run a shipped sh script with its tools stubbed as shell functions

A `bin/*.sh` that dev hands to `sh -c` can be run for real in a test:
prepend a preamble defining `brew() { … }`, `git() { … }`, `dev() { … }`
to the script's text and run the pair as one `sh -c` program against a
`HOME` in a tmpdir. Functions shadow PATH lookup, which a shim directory
cannot — the scripts prepend Linuxbrew's bin to PATH, so a runner with a
real Linuxbrew would win over any shim. The stubs record what they were
called with (and any state worth seeing at call time) into a file the
test reads back.

Wrong — only grepping the script's text, which proves the line exists
and nothing about order or effect:

    script.include?("chmod g-w,o-w")

Right (test/dev/container_dev_provisioner_test.rb) — a 775 `~/.homebrew`
in a tmp HOME, the script run with
`test/support/container_provision_stubs.sh` ahead of it, then the mode
asserted from `File.stat` and the first logged brew call checked to have
already seen the hardened dir.

Text-matching tests stay for contract lines (pins, flags); the real run
is for behaviour. Keep the preamble in a support file, not a heredoc
(see rspock-no-foreign-heredocs).

learned-from: dev#406 build pass — the issue asked for "a test asserting
the mode after a provision against a dir pre-set to 775", which no text
match can give.
date: 2026-11-02
