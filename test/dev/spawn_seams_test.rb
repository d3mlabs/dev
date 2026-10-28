# typed: false
# frozen_string_literal: true

require "test_helper"

# `shadowenv exec` is spawned from exactly two places — ShadowenvExec (the
# project-toolchain seam) and CommandRunner (the direct run) — and the
# second derives its child env from the first. Every regression in this
# family (dev#180, #274, #306, and the CommandRunner repeat of #274) was a
# spawn site keeping its own idea of what to clear; the fix each time was
# a key added where the symptom showed and not elsewhere. This test makes
# a third site a failing build rather than the next incident: anyone
# adding one either routes through ShadowenvExec or extends the allowlist
# here, in a diff a reviewer can see. Source-parsed like bin_dev_test's
# unset guard — the invariant is about the code, so the code is read.
transform!(RSpock::AST::Transformation)
class Dev::SpawnSeamsTest < Minitest::Test
  DEV_ROOT = File.expand_path("../..", __dir__)

  # The two seams. A line spawning `shadowenv exec` anywhere else under
  # lib/ or src/ fails the suite.
  SHADOWENV_EXEC_SEAMS = %w[
    lib/dev/deps/shadowenv_exec.rb
    src/dev/command_runner.rb
  ].freeze

  # An argv that starts `shadowenv exec`, in any of Ruby's spellings:
  # `"shadowenv", "exec"`, `%w[shadowenv exec`, or the two words inside
  # one string. Comment lines are skipped — the seams explain themselves
  # by naming the command they run.
  SPAWN_PATTERN = /(?:["']shadowenv["']\s*,\s*["']exec["']|%w\[\s*shadowenv\s+exec|["']shadowenv exec)/

  test "shadowenv exec is spawned from exactly the two known seams" do
    Given "every Ruby source under lib/ and src/"
    sources = Dir.glob(%w[lib/**/*.rb src/**/*.rb], base: DEV_ROOT)

    When "looking for lines that build a shadowenv exec argv"
    spawning = sources.select do |relative|
      File.readlines(File.join(DEV_ROOT, relative)).any? do |line|
        !line.lstrip.start_with?("#") && line.match?(SPAWN_PATTERN)
      end
    end

    Then "the set is exactly the allowlist — no stray seam, and both known ones still there"
    spawning.sort == SHADOWENV_EXEC_SEAMS.sort
  end

  test "the direct run's child env is ShadowenvExec's scrub, derived, not a copy" do
    Given "CommandRunner's source"
    source = File.read(File.join(DEV_ROOT, "src/dev/command_runner.rb"))

    Expect "child_env references the shared constant and spells no scrub key of its own"
    source.include?("Dev::Deps::ShadowenvExec::RUBY_ENV_SCRUB")
    !source.match?(/["']GEM_HOME["']\s*=>/)
    !source.match?(/["']__shadowenv_data["']/)
  end
end
