# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/tap_commit_carryover"
require "dev/deps/dependency"

transform!(RSpock::AST::Transformation)
class Dev::Deps::TapCommitCarryoverTest < Minitest::Test
  OLD = "0f1ba9eae11d4e14c2722f1aab1f08ffab81caa3"
  NEW = "7d2877ebf7869d8bd3a586c4a89cd2481a1501a9"

  # A brew pin as the Resolver mints it and as the Lockfile reads it back.
  def formula(name, version:, commit:, group: :build, tap: nil, platforms: ["x86_64_linux"], metadata: {})
    md = { "format" => platforms.include?("x86_64_linux") ? "bottle" : "source" }
    md["tap"] = tap if tap
    md["tap_commit"] = commit if commit
    md["platforms"] = platforms.to_h { |t| [t, { "hash" => "SHA256=#{name}-#{version}-#{t}", "link" => "https://x/#{t}" }] } if platforms.any?
    Dev::Deps::Dependency.new(name:, integration: :brew, group:, version:, hash: nil, metadata: md.merge(metadata))
  end

  def commits(deps)
    deps.to_h { |dep| [dep.name, dep.metadata["tap_commit"]] }
  end

  test "keeps a tap's previous commit when none of its pins changed" do
    Given "the same two core formulae, re-resolved at a newer core HEAD"
    previous = [formula("cmake", version: "4.4.4", commit: OLD), formula("ninja", version: "1.13.2", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW), formula("ninja", version: "1.13.2", commit: NEW)]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then "the pins carry the previous commit — nothing in the tap moved, so neither does the lock"
    commits(result) == { "cmake" => OLD, "ninja" => OLD }
    result.map { |dep| dep.metadata.except("tap_commit") } == resolved.map { |dep| dep.metadata.except("tap_commit") }
  end

  test "moves the whole tap to today's commit when one of its formulae changed: #{description}" do
    Given "two core formulae, one of which #{description}"
    previous = [formula("cmake", version: "4.4.3", commit: OLD), formula("ninja", version: "1.13.2", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.3", commit: NEW, **change), formula("ninja", version: "1.13.2", commit: NEW)]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then "every pin of the tap takes today's commit — one checkout per tap"
    commits(result) == { "cmake" => NEW, "ninja" => NEW }

    Where
    description               | change
    "bumped its version"      | { version: "4.4.4" }
    "rebuilt its bottles"     | { platforms: ["x86_64_linux", "arm64_tahoe"] }
    "lost its image bottle"   | { platforms: ["arm64_tahoe"] }
    "changed group"           | { group: :app }
    "gained a host gate"      | { metadata: { "host" => "darwin" } }
  end

  test "moves the tap when a formula was added to or removed from it: #{description}" do
    Given "a tap whose formula set #{description}"
    previous = before.map { |name, version| formula(name, version:, commit: OLD) }
    resolved = after.map { |name, version| formula(name, version:, commit: NEW) }

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then "the tap's commit is today's"
    result.all? { |dep| dep.metadata["tap_commit"] == NEW }

    Where
    description | before                                   | after
    "grew"      | { "cmake" => "4.4.4" }                   | { "cmake" => "4.4.4", "ninja" => "1.13.2" }
    "shrank"    | { "cmake" => "4.4.4", "ninja" => "1.13.2" } | { "cmake" => "4.4.4" }
  end

  test "decides per tap: an unchanged tap keeps its commit while a changed one moves" do
    Given "a core formula that did not change and a third-party formula that did"
    previous = [
      formula("cmake", version: "4.4.4", commit: OLD),
      formula("wwise-cli", version: "0.2.3", commit: "aaa", tap: "d3mlabs/d3mlabs", platforms: []),
    ]
    resolved = [
      formula("cmake", version: "4.4.4", commit: NEW),
      formula("wwise-cli", version: "0.2.4", commit: "bbb", tap: "d3mlabs/d3mlabs", platforms: []),
    ]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then
    commits(result) == { "cmake" => OLD, "wwise-cli" => "bbb" }
  end

  test "carries nothing from a lock that predates tap_commit" do
    Given "an unchanged formula whose previous pin has no commit"
    previous = [formula("cmake", version: "4.4.4", commit: nil)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then "today's commit stands"
    commits(result) == { "cmake" => NEW }
  end

  test "carries nothing from a pin in the pre-platforms shape — its facts differ, so the tap moved" do
    Given "a previous pin with a writer's hash and no platforms block"
    previous = [Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.4",
      hash: "SHA256=mac", metadata: { "tap_commit" => OLD, "format" => "bottle" })]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then
    commits(result) == { "cmake" => NEW }
  end

  test "carries nothing when there is no previous lock" do
    Given "a first resolution"
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, [])

    Then
    commits(result) == { "cmake" => NEW }
  end

  test "keeps the previous commit only when the tap's previous pins agree on one" do
    Given "a hand-merged lock pinning core at two commits, and an otherwise unchanged resolution"
    previous = [formula("cmake", version: "4.4.4", commit: OLD), formula("ninja", version: "1.13.2", commit: "other")]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW), formula("ninja", version: "1.13.2", commit: NEW)]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then "today's commit heals the conflict instead of preserving it"
    commits(result) == { "cmake" => NEW, "ninja" => NEW }
  end

  test "leaves casks and other integrations untouched" do
    Given "a cask and a gh pin beside an unchanged formula"
    cask = Dev::Deps::Dependency.new(name: "docker", integration: :brew, group: :app, version: "4.0", hash: nil, metadata: { "cask" => true })
    gh = Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build, version: "5.6.1", hash: nil, metadata: { "repo" => "x/y" })
    previous = [formula("cmake", version: "4.4.4", commit: OLD), cask, gh]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW), cask, gh]

    When "carrying over"
    result = Dev::Deps::TapCommitCarryover.new.apply(resolved, previous)

    Then "the formula carries; the others are the very same pins, in order"
    result[0].metadata["tap_commit"] == OLD
    result[1].equal?(cask)
    result[2].equal?(gh)
  end
end
