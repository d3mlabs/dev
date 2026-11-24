# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/self_contained_tree"
require "fileutils"
require "pathname"
require "tmpdir"

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
  # lib/ fails the suite.
  SHADOWENV_EXEC_SEAMS = %w[
    lib/dev/deps/shadowenv_exec.rb
    lib/dev/cli/command_runner.rb
  ].freeze

  # An argv that starts `shadowenv exec`, in any of Ruby's spellings:
  # `"shadowenv", "exec"`, `%w[shadowenv exec`, or the two words inside
  # one string. Comment lines are skipped — the seams explain themselves
  # by naming the command they run.
  SPAWN_PATTERN = /(?:["']shadowenv["']\s*,\s*["']exec["']|%w\[\s*shadowenv\s+exec|["']shadowenv exec)/

  test "shadowenv exec is spawned from exactly the two known seams" do
    Given "every Ruby source under lib/"
    sources = Dir.glob("lib/**/*.rb", base: DEV_ROOT)

    When "looking for lines that build a shadowenv exec argv"
    spawning = sources.select do |relative|
      File.readlines(File.join(DEV_ROOT, relative)).any? do |line|
        !line.lstrip.start_with?("#") && line.match?(SPAWN_PATTERN)
      end
    end

    Then "the set is exactly the allowlist — no stray seam, and both known ones still there"
    spawning.sort == SHADOWENV_EXEC_SEAMS.sort
  end

  # Env hygiene happens once, in bin/dev's sh layer. Neither seam clears a
  # key of its own: a `"KEY" => nil` in either is per-spawn hygiene coming
  # back (dev#180 → #274 → #306 → #333, each a key one seam nil'd and the
  # other did not, or nil'd without its pair).
  test "neither seam nils any env key for its child" do
    Given "both seams' sources, comments stripped"
    sources = SHADOWENV_EXEC_SEAMS.to_h do |seam|
      code = File.readlines(File.join(DEV_ROOT, seam)).reject { |line| line.lstrip.start_with?("#") }.join
      [seam, code]
    end

    Expect "no seam spells a nil'd env key, and the old pair is gone from both"
    sources.values.none? { |code| code.match?(/["'][A-Za-z_]+["']\s*=>\s*nil\b/) }
    sources.values.none? { |code| code.match?(/["'](?:GEM_HOME|__shadowenv_data)["']/) }
  end

  # A self-contained tree's `bin/<name>` launcher is a spawn seam dev
  # writes to disk rather than runs — the one kind the source scan above
  # cannot see. It is bin/dev's sh half: the harness activation unset, the
  # keg's Ruby exec'd, nothing else. An `export` would hand the tool's
  # process (and its children — a `dev` in a checkout, an agent's `bundle
  # exec`) a foreign bundler activation; a `GEM_` key cleared or set would
  # take the caller's gem env from them. Both are the
  # launcher-exports-into-process shape of dev#180, compensated by the
  # scrubs #274/#306/#333 then undid.
  test "a self-contained tree's generated launcher exports nothing and names no gem-env key" do
    Given "a self-contained tree with gems and an executable, binstubbed"
    root = Pathname(Dir.mktmpdir("dev-spawn-seams-"))
    (root / "exe").mkpath
    (root / "dependencies.rb").write("Dev::Deps.define { ruby \"4.0.6\" }\n")
    (root / "deps.lock").write("ruby:\n  ruby:\n    group: app\n    version: 4.0.6\n")
    (root / "Gemfile").write(%(source "https://rubygems.org"\n))
    (root / "exe/tool").write("#!/usr/bin/env ruby\n")
    Dev::Deps::SelfContainedTree.new(root:).gem_bundle.binstub!(ruby: Pathname("/opt/homebrew/opt/ruby/bin/ruby"))
    launcher = (root / "bin/tool").read

    Expect "the script unsets bin/dev's harness list, exports nothing, and never spells a GEM_ key"
    launcher.lines.one? { |line| line.start_with?("unset ") }
    launcher.lines.none? { |line| line.lstrip.start_with?("export ") }
    !launcher.match?(/\bGEM_[A-Z_]*\b/)

    Cleanup
    FileUtils.rm_rf(root)
  end
end
