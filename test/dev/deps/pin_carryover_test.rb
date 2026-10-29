# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_scheme"
require "dev/deps/declaration"
require "dev/deps/dependency"
require "dev/deps/gem_scheme"
require "dev/deps/pin_carryover"
require "dev/deps/scope"
require "dev/deps/scoped_declaration"
require "dev/deps/unlock_set"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PinCarryoverTest < Minitest::Test
  OLD = "0f1ba9eae11d4e14c2722f1aab1f08ffab81caa3"
  NEW = "7d2877ebf7869d8bd3a586c4a89cd2481a1501a9"
  BOTTLED = ["arm64_tahoe", "x86_64_linux"].freeze

  # A brew pin as the Resolver mints it and as the Lockfile reads it back.
  def formula(name, version:, commit:, integration: :brew, group: :build, tap: nil, suffix: nil, platforms: BOTTLED, metadata: {})
    md = { "format" => platforms.include?("x86_64_linux") ? "bottle" : "source" }
    md["tap"] = tap if tap
    md["version_suffix"] = suffix if suffix
    md["tap_commit"] = commit if commit
    md["platforms"] = platforms.to_h { |t| [t, { "hash" => "SHA256=#{name}-#{version}-#{t}", "link" => "https://x/#{name}/#{version}/#{t}" }] } if platforms.any?
    Dev::Deps::Dependency.new(name:, integration:, group:, version:, hash: nil, metadata: md.merge(metadata))
  end

  def declared(name, integration: :brew, constraint: {}, tap: nil, group: :build, host: nil)
    Dev::Deps::ScopedDeclaration.new(
      declaration: Dev::Deps::Declaration.new(name:, integration:, constraint:, source: tap),
      scope: Dev::Deps::Scope.new(group:, host:),
    )
  end

  def carryover
    Dev::Deps::PinCarryover.new(
      schemes: { brew: Dev::Deps::BrewScheme.new, ruby: Dev::Deps::GemScheme.new, python: Dev::Deps::BrewScheme.new },
    )
  end

  def versions(pins) = pins.to_h { |dep| [dep.name, dep.version] }
  def commits(pins) = pins.to_h { |dep| [dep.name, dep.metadata["tap_commit"]] }
  def moves(outcome) = outcome.moved.map { |move| [move.name, move.from, move.to, move.reason] }

  test "keeps every brew pin whose declaration did not change — cellbound-3d#319: one gh entry added on a newer index" do
    Given "a lock with two core formulae, and a resolution on an index a day newer that adds a gh pin"
    declarations = [declared("python", integration: :python, constraint: { "version" => "3.12" }), declared("cmake"),
                    declared("gh", integration: :gh, constraint: { "tag" => "v2.81.0" }, tap: "cli/cli")]
    previous = [
      formula("python", integration: :python, version: "3.12.15", suffix: "3.12", commit: OLD),
      formula("cmake", version: "4.4.4", commit: OLD),
    ]
    gh = Dev::Deps::Dependency.new(name: "gh", integration: :gh, group: :build, version: "v2.81.0", hash: "SHA256=gh",
      metadata: { "repo" => "cli/cli" })
    resolved = [
      formula("python", integration: :python, version: "3.12.16", suffix: "3.12", commit: NEW),
      formula("cmake", version: "4.4.5", commit: NEW),
      gh,
    ]

    When "carrying over with nothing floated"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "the brew pins are the lock's, byte for byte, and the gh pin is the resolution's"
    outcome.pins[0] == previous[0]
    outcome.pins[1] == previous[1]
    outcome.pins[2].equal?(gh)
    outcome.kept.map(&:name) == ["python", "cmake"]
    outcome.moved == []
  end

  test "keeps a ranged interpreter at the lock's patch while the range still admits it" do
    Given "ruby '~> 4.0' locked at 4.0.5, and a tap that now carries 4.0.6"
    declarations = [declared("ruby", integration: :ruby, constraint: { "version" => "~> 4.0" }, tap: "d3mlabs/d3mlabs", group: :app)]
    previous = [formula("ruby", integration: :ruby, version: "4.0.5", suffix: "4.0.5", tap: "d3mlabs/d3mlabs", group: :app, commit: OLD)]
    resolved = [formula("ruby", integration: :ruby, version: "4.0.6", suffix: "4.0.6", tap: "d3mlabs/d3mlabs", group: :app, commit: NEW)]

    When "carrying over"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "the lock keeps 4.0.5 — a patch upgrade is a re-lock the author asks for"
    versions(outcome.pins) == { "ruby" => "4.0.5" }
    commits(outcome.pins) == { "ruby" => OLD }
    outcome.moved == []
  end

  test "floats a pin whose declaration changed: #{description}" do
    Given "a lock written for one declaration, and a resolution of a changed one"
    previous = [formula("llvm", version: "18.1.8", suffix: "18", commit: OLD)]
    resolved = [formula("llvm", version: "19.1.0", suffix: "19", commit: NEW, **pin_change)]

    When "carrying over with nothing floated"
    declarations = [declared("llvm", **declaration)]
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "the resolution stands and the move names the cause"
    outcome.pins == resolved
    moves(outcome) == [["llvm", "18.1.8", "19.1.0", "declaration changed"]]

    Where
    description               | declaration | pin_change
    "constraint moved to 19"  | { constraint: { "version" => "19" } } | {}
    "tap changed"             | { tap: "d3mlabs/d3mlabs" }           | { tap: "d3mlabs/d3mlabs" }
    "group changed"           | { group: :app }                      | { group: :app }
    "gained a host gate"      | { host: :darwin }                    | { metadata: { "host" => "darwin" } }
  end

  test "floats an exact interpreter pin the lock no longer satisfies" do
    Given "ruby '4.0.6' with the lock at 4.0.5"
    declarations = [declared("ruby", integration: :ruby, constraint: { "version" => "4.0.6" }, tap: "d3mlabs/d3mlabs", group: :app)]
    previous = [formula("ruby", integration: :ruby, version: "4.0.5", suffix: "4.0.5", tap: "d3mlabs/d3mlabs", group: :app, commit: OLD)]
    resolved = [formula("ruby", integration: :ruby, version: "4.0.6", suffix: "4.0.6", tap: "d3mlabs/d3mlabs", group: :app, commit: NEW)]

    When "carrying over"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then
    versions(outcome.pins) == { "ruby" => "4.0.6" }
    moves(outcome) == [["ruby", "4.0.5", "4.0.6", "declaration changed"]]
  end

  test "floats an interpreter pin whose locked version its scheme cannot read" do
    Given "ruby '~> 4.0' locked at a brew revision (4.0.5_1), which is not a rubygems version"
    declarations = [declared("ruby", integration: :ruby, constraint: { "version" => "~> 4.0" }, tap: "d3mlabs/d3mlabs", group: :app)]
    previous = [formula("ruby", integration: :ruby, version: "4.0.5_1", suffix: "4.0.5", tap: "d3mlabs/d3mlabs", group: :app, commit: OLD)]
    resolved = [formula("ruby", integration: :ruby, version: "4.0.6", suffix: "4.0.6", tap: "d3mlabs/d3mlabs", group: :app, commit: NEW)]

    When "carrying over"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "an unreadable lock version cannot be shown to satisfy the ask, so the pin re-resolves"
    versions(outcome.pins) == { "ruby" => "4.0.6" }
    moves(outcome) == [["ruby", "4.0.5_1", "4.0.6", "declaration changed"]]
  end

  test "floats, with the reason, a moved formula the lock records no bottle for: #{description}" do
    Given "an unchanged declaration whose lock pin #{description}"
    prior = if bottles.nil?
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.4", hash: "SHA256=mac",
        metadata: { "tap_commit" => OLD, "format" => "bottle" })
    else
      formula("cmake", version: "4.4.4", commit: OLD, platforms: bottles)
    end
    resolved = [formula("cmake", version: "4.4.5", commit: NEW)]

    When "carrying over"
    outcome = carryover.apply(declarations: [declared("cmake")], previous: [prior], resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "no host could converge to the lock's version, so it floats and says why"
    versions(outcome.pins) == { "cmake" => "4.4.5" }
    outcome.kept == []
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "the lock records no bottle for 4.4.4, so no host could converge to it"]]

    Where
    description                     | bottles
    "predates bottle records"       | nil
    "is a formula with no bottles"  | []
  end

  test "takes the resolution's shape for an unmoved formula the lock records no bottle for, moving nothing" do
    Given "a lock pin in the pre-bottles shape, re-resolved to the same version with its bottles"
    prior = Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.4", hash: "SHA256=mac",
      metadata: { "tap_commit" => OLD, "format" => "bottle" })
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "carrying over"
    outcome = carryover.apply(declarations: [declared("cmake")], previous: [prior], resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "the lock gains the bottles at today's commit; the version did not move"
    outcome.pins == resolved
    outcome.moved == []
  end

  test "floats the named declaration and keeps the rest" do
    Given "two core formulae, both moved upstream, one named"
    declarations = [declared("cmake"), declared("python", integration: :python, constraint: { "version" => "3.12" })]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), formula("python", integration: :python, version: "3.12.15", suffix: "3.12", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW), formula("python", integration: :python, version: "3.12.16", suffix: "3.12", commit: NEW)]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.new(names: ["cmake"]))

    Then "cmake is today's at today's commit; python is the lock's, commit included"
    versions(outcome.pins) == { "cmake" => "4.4.5", "python" => "3.12.15" }
    commits(outcome.pins) == { "cmake" => NEW, "python" => OLD }
    outcome.kept.map(&:name) == ["python"]
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "named"]]
  end

  test "floats what a named declaration pulls in through integration needs" do
    Given "an xcode declaration whose integration needs the xcodes formula, both moved upstream"
    declarations = [
      declared("xcode", integration: :xcode, group: :app),
      declared("xcodes", tap: "xcodesorg/made", group: :app, host: :darwin),
    ]
    previous = [formula("xcodes", version: "1.6.1", tap: "xcodesorg/made", group: :app, commit: OLD,
      metadata: { "host" => "darwin", "needed_by" => ["xcode"] })]
    resolved = [formula("xcodes", version: "1.6.2", tap: "xcodesorg/made", group: :app, commit: NEW,
      metadata: { "host" => "darwin", "needed_by" => ["xcode"] })]

    When "dev deps update xcode"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.new(names: ["xcode"]))

    Then "xcodes floats with the declaration that needs it"
    versions(outcome.pins) == { "xcodes" => "1.6.2" }
    moves(outcome) == [["xcodes", "1.6.1", "1.6.2", "named"]]
  end

  test "--all floats everything, carrying a commit only onto a pin nothing changed about" do
    Given "two core formulae, one moved upstream, one not"
    declarations = [declared("cmake"), declared("python", integration: :python, constraint: { "version" => "3.12" })]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), formula("python", integration: :python, version: "3.12.15", suffix: "3.12", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW), formula("python", integration: :python, version: "3.12.16", suffix: "3.12", commit: NEW)]

    When "dev deps update --all"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then "python is today's at today's commit; cmake's facts are the lock's, so its commit stays (ADR-0005, per pin)"
    versions(outcome.pins) == { "cmake" => "4.4.4", "python" => "3.12.16" }
    commits(outcome.pins) == { "cmake" => OLD, "python" => NEW }
    outcome.kept == []
    moves(outcome) == [["python", "3.12.15", "3.12.16", "--all"]]
  end

  test "a re-resolved pin takes today's commit when anything about it changed: #{description}" do
    Given "a floated formula that #{description}"
    previous = [formula("cmake", version: "4.4.4", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW, **change)]

    When "dev deps update --all"
    outcome = carryover.apply(declarations: [declared("cmake")], previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then
    commits(outcome.pins) == { "cmake" => NEW }

    Where
    description             | change
    "rebuilt its bottles"   | { platforms: ["x86_64_linux", "arm64_tahoe", "arm64_sequoia"] }
    "lost its image bottle" | { platforms: ["arm64_tahoe"] }
    "changed group"         | { group: :app }
  end

  test "a re-resolved pin stands at today's commit when the lock has none to carry" do
    Given "an unmoved formula whose lock pin predates tap_commit"
    previous = [formula("cmake", version: "4.4.4", commit: nil)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "dev deps update --all"
    outcome = carryover.apply(declarations: [declared("cmake")], previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then
    commits(outcome.pins) == { "cmake" => NEW }
  end

  test "reports a brew pin the lock did not have as added" do
    Given "a first resolution"
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "carrying over against no lock"
    outcome = carryover.apply(declarations: [declared("cmake")], previous: [], resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then
    outcome.pins == resolved
    moves(outcome) == [["cmake", nil, "4.4.4", "new"]]
  end

  test "a kept pin takes this resolution's provenance" do
    Given "a lock pin nobody needed, now needed by the xcode integration"
    declarations = [declared("xcodes", tap: "xcodesorg/made", group: :app)]
    previous = [formula("xcodes", version: "1.6.1", tap: "xcodesorg/made", group: :app, commit: OLD)]
    resolved = [formula("xcodes", version: "1.6.2", tap: "xcodesorg/made", group: :app, commit: NEW, metadata: { "needed_by" => ["xcode"] })]

    When "carrying over"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "the version, bottles and commit are the lock's; needed_by is today's"
    pin = outcome.pins.fetch(0)
    pin.version == "1.6.1"
    pin.metadata["tap_commit"] == OLD
    pin.metadata["platforms"] == previous.fetch(0).metadata["platforms"]
    pin.metadata["needed_by"] == ["xcode"]
  end

  test "a subset re-lock carries every pin it did not float verbatim, whatever its channel" do
    Given "a lock with a gh tree and a ficsit mod, both resolving differently today, and a named brew formula"
    declarations = [declared("cmake"), declared("UnrealEngine", integration: :gh, constraint: { "tag" => "5.6.2" }, tap: "x/y"),
                    declared("SML", integration: :ficsit, constraint: { "version" => "^3.12" })]
    gh_before = Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build, version: "5.6.1", hash: "SHA256=a", metadata: { "repo" => "x/y" })
    sml_before = Dev::Deps::Dependency.new(name: "SML", integration: :ficsit, group: :build, version: "3.12.1", hash: "SHA256=s1", metadata: {})
    previous = [formula("cmake", version: "4.4.4", commit: OLD), gh_before, sml_before]
    resolved = [
      formula("cmake", version: "4.4.5", commit: NEW),
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build, version: "5.6.2", hash: "SHA256=b", metadata: { "repo" => "x/y" }),
      Dev::Deps::Dependency.new(name: "SML", integration: :ficsit, group: :build, version: "3.12.2", hash: "SHA256=s2", metadata: {}),
    ]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.new(names: ["cmake"]))

    Then "cmake moved; the gh tree and the mod are the lock's pins"
    versions(outcome.pins) == { "cmake" => "4.4.5", "UnrealEngine" => "5.6.1", "SML" => "3.12.1" }
    outcome.pins[1].equal?(gh_before)
    outcome.pins[2].equal?(sml_before)
    outcome.kept.map(&:name) == ["UnrealEngine", "SML"]
  end

  test "a subset re-lock takes the resolution for a named non-brew pin and for one the lock never had" do
    Given "a gh tree named on the command line and a mod with no lock pin"
    declarations = [declared("UnrealEngine", integration: :gh, constraint: { "tag" => "5.6.2" }, tap: "x/y"),
                    declared("SML", integration: :ficsit, constraint: { "version" => "^3.12" })]
    previous = [Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build, version: "5.6.1", hash: "SHA256=a", metadata: {})]
    resolved = [
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build, version: "5.6.2", hash: "SHA256=b", metadata: {}),
      Dev::Deps::Dependency.new(name: "SML", integration: :ficsit, group: :build, version: "3.12.2", hash: "SHA256=s2", metadata: {}),
    ]

    When "dev deps update UnrealEngine"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.new(names: ["UnrealEngine"]))

    Then
    outcome.pins == resolved
    outcome.kept == []
  end

  test "a full re-lock leaves casks and non-brew pins to the resolution" do
    Given "a cask and a gh pin beside a kept formula"
    cask = Dev::Deps::Dependency.new(name: "docker", integration: :cask, group: :app, version: nil, hash: nil, metadata: { "cask" => true })
    gh = Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build, version: "5.6.1", hash: nil, metadata: { "repo" => "x/y" })
    previous = [formula("cmake", version: "4.4.4", commit: OLD), cask, gh]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW), cask, gh]

    When "carrying over"
    outcome = carryover.apply(declarations: [declared("cmake")], previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then "the formula is kept; the others are the very same pins, in order"
    outcome.pins[0] == previous[0]
    outcome.pins[1].equal?(cask)
    outcome.pins[2].equal?(gh)
  end

  test "a brew pin with no declaration behind it floats rather than being kept on a guess" do
    Given "a resolved formula no declaration or need accounts for"
    previous = [formula("cmake", version: "4.4.4", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW)]

    When "carrying over with no declarations"
    outcome = carryover.apply(declarations: [], previous:, resolved:, unlock: Dev::Deps::UnlockSet.none)

    Then
    versions(outcome.pins) == { "cmake" => "4.4.5" }
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "declaration changed"]]
  end
end
