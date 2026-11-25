# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_repository"
require "dev/deps/brew_scheme"
require "dev/deps/selection_rule"
require "dev/deps/declaration"
require "dev/deps/dependency"
require "dev/deps/gem_scheme"
require "dev/deps/oci_repository"
require "dev/deps/pep440_scheme"
require "dev/deps/pin_carryover"
require "dev/deps/requirement"
require "dev/deps/resolver"
require "dev/deps/scope"
require "dev/deps/scoped_declaration"
require "dev/deps/series_head"
require "dev/deps/steam_scheme"
require "dev/deps/tag_scheme"
require "dev/deps/unlock_set"
require "dev/lifecycle/series"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PinCarryoverTest < Minitest::Test
  OLD = "0f1ba9eae11d4e14c2722f1aab1f08ffab81caa3"
  NEW = "7d2877ebf7869d8bd3a586c4a89cd2481a1501a9"
  BOTTLED = ["arm64_tahoe", "x86_64_linux"].freeze
  NO_SOURCE = "the lock records no source for %s, so it cannot be kept"

  # A brew pin as the Resolver mints it and as the Lockfile reads it back:
  # its source is the tap at the commit.
  def formula(name, version:, commit:, integration: :brew, group: :build, tap: nil, suffix: nil, platforms: BOTTLED, metadata: {}, rule: nil)
    md = { "format" => platforms.include?("x86_64_linux") ? "bottle" : "source" }
    md["tap"] = tap if tap
    md["version_suffix"] = suffix if suffix
    md["tap_commit"] = commit if commit
    md["platforms"] = platforms.to_h { |t| [t, { "hash" => "SHA256=#{name}-#{version}-#{t}", "link" => "https://x/#{name}/#{version}/#{t}" }] } if platforms.any?
    source = commit && Dev::Deps::BrewRepository.source_at(tap, commit)
    Dev::Deps::Dependency.new(name:, integration:, group:, version:, hash: nil, source:, metadata: md.merge(metadata), rule:)
  end

  # A pip pin: its source is the exact requirement, unless the lock predates sources.
  def pip(name, version, sourced: true, group: :app)
    source = sourced ? "#{name}==#{version}" : nil
    Dev::Deps::Dependency.new(name:, integration: :pip, group:, version:, hash: "SHA256=#{name}-#{version}", source:, metadata: {})
  end

  def declared(name, integration: :brew, requirement: nil, tap: nil, group: :build, host: nil, revision: nil)
    Dev::Deps::ScopedDeclaration.new(
      declaration: Dev::Deps::Declaration.new(
        name:, integration:, requirement: Dev::Deps::Requirement.parse(requirement), source: tap, revision:,
      ),
      scope: Dev::Deps::Scope.new(group:, host:),
    )
  end

  def carryover
    Dev::Deps::PinCarryover.new(
      schemes: {
        brew: Dev::Deps::BrewScheme.new, ruby: Dev::Deps::GemScheme.new, python: Dev::Deps::BrewScheme.new,
        pip: Dev::Deps::Pep440Scheme.new, gh: Dev::Deps::TagScheme.new, steam: Dev::Deps::SteamScheme.new,
      },
    )
  end

  def versions(pins)
    pins.to_h { |dep| [dep.name, dep.version] }
  end

  def commits(pins)
    pins.to_h { |dep| [dep.name, dep.metadata["tap_commit"]] }
  end

  def sources(pins)
    pins.to_h { |dep| [dep.name, dep.source] }
  end

  def moves(outcome)
    outcome.moved.map { |move| [move.name, move.from, move.to, move.reason] }
  end

  def update(*names)
    Dev::Deps::UnlockSet.new(names:)
  end

  test "a bare update moves every pin to the resolution's, across channels, and keeps nothing" do
    Given "a lock with a brew formula, an open-range pip package and a gh release, all newer today"
    declarations = [declared("cmake"), declared("kimimaro", integration: :pip, requirement: ">= 5", group: :app),
                    declared("gh", integration: :gh, requirement: "= 2.81.0", tap: "cli/cli")]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), pip("kimimaro", "5.8.5"),
                Dev::Deps::Dependency.new(name: "gh", integration: :gh, group: :build, version: "v2.80.0", hash: nil, source: "a" * 40, metadata: { "repo" => "cli/cli" })]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW), pip("kimimaro", "5.9.0"),
                Dev::Deps::Dependency.new(name: "gh", integration: :gh, group: :build, version: "v2.81.0", hash: nil, source: "b" * 40, metadata: { "repo" => "cli/cli" })]

    When "dev deps update"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then "every pin is today's; each move is reported with no reason beyond the verb"
    outcome.pins == resolved
    outcome.kept == []
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", nil], ["kimimaro", "5.8.5", "5.9.0", nil], ["gh", "v2.80.0", "v2.81.0", nil]]
  end

  test "a bare update carries a brew pin's provenance only when nothing about the pin changed (ADR-0005, per pin)" do
    Given "two core formulae, one moved upstream, one not"
    declarations = [declared("cmake"), declared("python", integration: :python, requirement: "~> 3.12.0")]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), formula("python", integration: :python, version: "3.12.15", suffix: "3.12", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW), formula("python", integration: :python, version: "3.12.16", suffix: "3.12", commit: NEW)]

    When "dev deps update"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then "python is today's at today's commit and source; cmake's facts are the lock's, so its commit and source stay"
    versions(outcome.pins) == { "cmake" => "4.4.4", "python" => "3.12.16" }
    commits(outcome.pins) == { "cmake" => OLD, "python" => NEW }
    sources(outcome.pins) == { "cmake" => "homebrew/core@#{OLD}", "python" => "homebrew/core@#{NEW}" }
    outcome.kept == []
    moves(outcome) == [["python", "3.12.15", "3.12.16", nil]]
  end

  test "a re-resolved pin takes today's provenance when anything about it changed: #{description}" do
    Given "a formula that #{description}"
    previous = [formula("cmake", version: "4.4.4", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW, **change)]

    When "dev deps update"
    outcome = carryover.apply(declarations: [declared("cmake")], previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then
    commits(outcome.pins) == { "cmake" => NEW }
    sources(outcome.pins) == { "cmake" => "homebrew/core@#{NEW}" }

    Where
    description             | change
    "rebuilt its bottles"   | { platforms: ["x86_64_linux", "arm64_tahoe", "arm64_sequoia"] }
    "lost its image bottle" | { platforms: ["arm64_tahoe"] }
    "changed group"         | { group: :app }
  end

  test "a re-resolved pin stands at today's provenance when the lock has none to carry" do
    Given "an unmoved formula whose lock pin predates tap commits and sources"
    previous = [formula("cmake", version: "4.4.4", commit: nil)]
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "dev deps update"
    outcome = carryover.apply(declarations: [declared("cmake")], previous:, resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then
    commits(outcome.pins) == { "cmake" => NEW }
    sources(outcome.pins) == { "cmake" => "homebrew/core@#{NEW}" }
  end

  test "update <name> moves the named pin and keeps every unchanged pin the lock records a source for, whatever its channel" do
    Given "a brew formula named, a pip package and a brew interpreter beside it, all newer today"
    declarations = [declared("cmake"), declared("kimimaro", integration: :pip, requirement: ">= 5", group: :app),
                    declared("python", integration: :python, requirement: "~> 3.12.0")]
    kimimaro = pip("kimimaro", "5.8.5")
    previous = [formula("cmake", version: "4.4.4", commit: OLD), kimimaro, formula("python", integration: :python, version: "3.12.15", suffix: "3.12", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW), pip("kimimaro", "5.9.0"), formula("python", integration: :python, version: "3.12.16", suffix: "3.12", commit: NEW)]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "cmake is today's at today's commit; kimimaro and python are the lock's, byte for byte"
    versions(outcome.pins) == { "cmake" => "4.4.5", "kimimaro" => "5.8.5", "python" => "3.12.15" }
    commits(outcome.pins) == { "cmake" => NEW, "kimimaro" => nil, "python" => OLD }
    outcome.pins[1] == kimimaro
    outcome.pins[2] == previous[2]
    outcome.kept.map(&:name) == ["kimimaro", "python"]
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "named"]]
  end

  test "update <name> re-resolves a pip pin whose requirement changed" do
    Given "nibabel '>=5.5' with the lock at 5.4.2, and cmake named"
    declarations = [declared("cmake"), declared("nibabel", integration: :pip, requirement: ">= 5.5", group: :app)]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), pip("nibabel", "5.4.2")]
    resolved = [formula("cmake", version: "4.4.4", commit: OLD), pip("nibabel", "5.5.0")]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "nibabel moves with the cause named; cmake, named but unmoved, is not a move"
    versions(outcome.pins) == { "cmake" => "4.4.4", "nibabel" => "5.5.0" }
    moves(outcome) == [["nibabel", "5.4.2", "5.5.0", "declaration changed"]]
    outcome.kept == []
  end

  test "update <name> re-resolves an unchanged pin the lock records no source for, and says so" do
    Given "a lock written before pins carried a source: a pip pin without one, beside a named formula"
    declarations = [declared("cmake"), declared("trimesh", integration: :pip, requirement: ">= 5", group: :app)]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), pip("trimesh", "5.2.0", sourced: false)]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW), pip("trimesh", "5.2.1")]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "trimesh is today's, with a source from now on, and the move names why it could not be kept"
    versions(outcome.pins) == { "cmake" => "4.4.5", "trimesh" => "5.2.1" }
    sources(outcome.pins) == { "cmake" => "homebrew/core@#{NEW}", "trimesh" => "trimesh==5.2.1" }
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "named"], ["trimesh", "5.2.0", "5.2.1", format(NO_SOURCE, "5.2.0")]]
    outcome.kept == []
  end

  test "update <name> keeps a brew pin a lock written before sources recorded a tap commit for, and re-resolves the rest once" do
    Given "the lock as Lockfile lifts it: the formula's source is its tap commit; the gh pin has none"
    declarations = [declared("jq"), declared("cmake"), declared("gh", integration: :gh, requirement: "= 2.81.0", tap: "cli/cli")]
    gh_before = Dev::Deps::Dependency.new(name: "gh", integration: :gh, group: :build, version: "v2.81.0", hash: nil, metadata: { "repo" => "cli/cli" })
    gh_today = Dev::Deps::Dependency.new(name: "gh", integration: :gh, group: :build, version: "v2.81.0", hash: nil, source: "b" * 40, metadata: { "repo" => "cli/cli" })
    previous = [formula("jq", version: "1.7", commit: OLD), formula("cmake", version: "4.4.4", commit: OLD), gh_before]
    resolved = [formula("jq", version: "1.8", commit: NEW), formula("cmake", version: "4.4.5", commit: NEW), gh_today]

    When "dev deps update jq"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("jq"))

    Then "cmake is kept by its lifted source; gh is today's, gaining its source without moving"
    versions(outcome.pins) == { "jq" => "1.8", "cmake" => "4.4.4", "gh" => "v2.81.0" }
    sources(outcome.pins) == { "jq" => "homebrew/core@#{NEW}", "cmake" => "homebrew/core@#{OLD}", "gh" => "b" * 40 }
    outcome.kept.map(&:name) == ["cmake"]
    moves(outcome) == [["jq", "1.7", "1.8", "named"]]
  end

  test "update <name> keeps a ranged interpreter at the lock's patch while the range still admits it" do
    Given "ruby '~> 4.0' locked at 4.0.5, a tap that now carries 4.0.6, and another declaration named"
    declarations = [declared("ruby", integration: :ruby, requirement: "~> 4.0", tap: "d3mlabs/d3mlabs", group: :app), declared("cmake")]
    previous = [formula("ruby", integration: :ruby, version: "4.0.5", suffix: "4.0.5", tap: "d3mlabs/d3mlabs", group: :app, commit: OLD)]
    resolved = [formula("ruby", integration: :ruby, version: "4.0.6", suffix: "4.0.6", tap: "d3mlabs/d3mlabs", group: :app, commit: NEW)]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "the lock keeps 4.0.5 — a patch upgrade is a re-lock the author asks for, bare or by name"
    versions(outcome.pins) == { "ruby" => "4.0.5" }
    commits(outcome.pins) == { "ruby" => OLD }
    outcome.moved == []
  end

  test "update <name> re-resolves a pin whose declaration changed: #{description}" do
    Given "a lock written for one declaration, and a resolution of a changed one, with another declaration named"
    previous = [formula("llvm", version: "18.1.8", suffix: "18", commit: OLD)]
    resolved = [formula("llvm", version: "19.1.0", suffix: "19", commit: NEW, **pin_change)]

    When "dev deps update jq"
    declarations = [declared("llvm", **declaration), declared("jq")]
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("jq"))

    Then "the resolution stands and the move names the cause"
    outcome.pins == resolved
    moves(outcome) == [["llvm", "18.1.8", "19.1.0", "declaration changed"]]

    Where
    description               | declaration | pin_change
    "requirement moved to 19" | { requirement: "~> 19.0" }           | {}
    "tap changed"             | { tap: "d3mlabs/d3mlabs" }           | { tap: "d3mlabs/d3mlabs" }
    "group changed"           | { group: :app }                      | { group: :app }
    "gained a host gate"      | { host: :darwin }                    | { metadata: { "host" => "darwin" } }
  end

  test "update <name> re-resolves an exact interpreter pin the lock no longer satisfies" do
    Given "ruby '4.0.6' with the lock at 4.0.5"
    declarations = [declared("ruby", integration: :ruby, requirement: "= 4.0.6", tap: "d3mlabs/d3mlabs", group: :app), declared("cmake")]
    previous = [formula("ruby", integration: :ruby, version: "4.0.5", suffix: "4.0.5", tap: "d3mlabs/d3mlabs", group: :app, commit: OLD)]
    resolved = [formula("ruby", integration: :ruby, version: "4.0.6", suffix: "4.0.6", tap: "d3mlabs/d3mlabs", group: :app, commit: NEW)]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then
    versions(outcome.pins) == { "ruby" => "4.0.6" }
    moves(outcome) == [["ruby", "4.0.5", "4.0.6", "declaration changed"]]
  end

  test "update <name> re-resolves an interpreter pin whose locked version its scheme cannot read" do
    Given "ruby '~> 4.0' locked at a brew revision (4.0.5_1), which is not a rubygems version"
    declarations = [declared("ruby", integration: :ruby, requirement: "~> 4.0", tap: "d3mlabs/d3mlabs", group: :app), declared("cmake")]
    previous = [formula("ruby", integration: :ruby, version: "4.0.5_1", suffix: "4.0.5", tap: "d3mlabs/d3mlabs", group: :app, commit: OLD)]
    resolved = [formula("ruby", integration: :ruby, version: "4.0.6", suffix: "4.0.6", tap: "d3mlabs/d3mlabs", group: :app, commit: NEW)]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "an unreadable lock version cannot be shown to satisfy the ask, so the pin re-resolves"
    versions(outcome.pins) == { "ruby" => "4.0.6" }
    moves(outcome) == [["ruby", "4.0.5_1", "4.0.6", "declaration changed"]]
  end

  test "update <name> keeps a revision-addressed pin at its revision and re-resolves one whose revision changed" do
    Given "an xcode at the lock's version and a gh commit the declaration moved, with a formula named"
    declarations = [
      declared("cmake"),
      declared("xcode", integration: :xcode, group: :app, revision: "26.1.1"),
      declared("json", integration: :gh, tap: "nlohmann/json", revision: "b" * 40),
    ]
    xcode = Dev::Deps::Dependency.new(name: "xcode", integration: :xcode, group: :app, version: "26.1.1", hash: nil, source: "26.1.1", metadata: {})
    previous = [xcode, Dev::Deps::Dependency.new(name: "json", integration: :gh, group: :build, version: "a" * 40, hash: nil, source: "a" * 40, metadata: { "repo" => "nlohmann/json" })]
    resolved = [xcode, Dev::Deps::Dependency.new(name: "json", integration: :gh, group: :build, version: "b" * 40, hash: nil, source: "b" * 40, metadata: { "repo" => "nlohmann/json" })]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then
    outcome.kept == [xcode]
    moves(outcome) == [["json", "a" * 40, "b" * 40, "declaration changed"]]
  end

  test "update <name> re-resolves an image pin whose floor moved to another tag" do
    Given "a floor pin resolved from ue5.8-3, and a declaration now naming ue5.8-4"
    floor = declared("cellbound-3d-linux", integration: :image, tap: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-4", group: :app)
    image = ->(tag, digest) do
      Dev::Deps::Dependency.new(name: "cellbound-3d-linux", integration: :image, group: :app, version: tag, hash: "SHA256=#{digest * 64}",
        source: "sha256:#{digest * 64}", metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base" })
    end

    When "dev deps update clang-format"
    outcome = carryover.apply(declarations: [floor, declared("clang-format", integration: :pip, group: :app)],
      previous: [image.call("ue5.8-3", "a")], resolved: [image.call("ue5.8-4", "b")], unlock: update("clang-format"))

    Then
    moves(outcome) == [["cellbound-3d-linux", "ue5.8-3", "ue5.8-4", "declaration changed"]]
  end

  test "update <name> re-resolves a steam pin every time: a branch tip has no source to be kept by" do
    Given "the public branch moved since the lock, and a formula named"
    declarations = [declared("cmake"), declared("SatisfactoryServer", integration: :steam, tap: "1690800", group: :app)]
    server = ->(build) { Dev::Deps::Dependency.new(name: "SatisfactoryServer", integration: :steam, group: :app, version: build, hash: nil, metadata: { "app" => "1690800", "branch" => "public" }) }
    previous = [formula("cmake", version: "4.4.4", commit: OLD), server.call("15400000")]
    resolved = [formula("cmake", version: "4.4.4", commit: OLD), server.call("15500000")]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "the tip is today's, and the move says why the lock could not hold the old one"
    versions(outcome.pins) == { "cmake" => "4.4.4", "SatisfactoryServer" => "15500000" }
    moves(outcome) == [["SatisfactoryServer", "15400000", "15500000", format(NO_SOURCE, "15400000")]]
  end

  test "update <name> leaves a cask to the resolution without reporting a move: it pins no version" do
    Given "a cask beside a named formula"
    cask = Dev::Deps::Dependency.new(name: "docker", integration: :cask, group: :app, version: nil, hash: nil, metadata: { "cask" => true })
    declarations = [declared("cmake"), declared("docker", integration: :cask, group: :app)]
    previous = [formula("cmake", version: "4.4.4", commit: OLD), cask]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW), cask]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then
    outcome.pins[1] == cask
    outcome.kept == []
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "named"]]
  end

  test "update <name> floats what the named declaration pulls in through integration needs" do
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
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("xcode"))

    Then "xcodes floats with the declaration that needs it"
    versions(outcome.pins) == { "xcodes" => "1.6.2" }
    moves(outcome) == [["xcodes", "1.6.1", "1.6.2", "named"]]
  end

  test "reports a pin the lock did not have as added, under #{description}" do
    Given "a first resolution"
    resolved = [formula("cmake", version: "4.4.4", commit: NEW)]

    When "carrying over against no lock"
    outcome = carryover.apply(declarations: [declared("cmake"), declared("jq")], previous: [], resolved:, unlock:)

    Then
    outcome.pins == resolved
    moves(outcome) == [["cmake", nil, "4.4.4", "new"]]

    Where
    description          | unlock
    "a bare update"      | Dev::Deps::UnlockSet.all
    "update <name>"      | Dev::Deps::UnlockSet.new(names: ["jq"])
  end

  test "a move carries the rule that chose its version, and a kept pin carries none" do
    Given "a gh pin the resolution chose as v1's head while the lock has the greater 1.4.0, beside a formula the lock keeps"
    head = Dev::Deps::SelectionRule::Head.new(head: Dev::Deps::SeriesHead.new(series: Dev::Lifecycle::Series.new(1), version: "1.3.0"))
    declarations = [declared("ai-flow", integration: :gh, requirement: "~> 1", tap: "d3mlabs/ai-flow", group: :app), declared("cmake")]
    previous = [gh_pin("1.4.0", "b" * 40), formula("cmake", version: "4.4.4", commit: OLD)]
    greatest = Dev::Deps::SelectionRule::Greatest.new(beside: [])
    resolved = [gh_pin("1.3.0", "a" * 40, rule: head), formula("cmake", version: "4.4.5", commit: NEW, rule: greatest)]

    When "dev deps update ai-flow, then a bare update of the first lock"
    subset = carryover.apply(declarations:, previous:, resolved:, unlock: update("ai-flow"))
    added = carryover.apply(declarations:, previous: [], resolved:, unlock: Dev::Deps::UnlockSet.all)

    Then "the gh move names the head; cmake is the lock's, with no rule of this resolution behind it; a new pin names its rule too"
    subset.moved.map { |move| [move.name, move.from, move.to, move.reason, move.rule] } == [["ai-flow", "1.4.0", "1.3.0", "named", head]]
    subset.kept.map(&:name) == ["cmake"]
    subset.pins.find { |pin| pin.name == "cmake" }.rule.nil?
    subset.pins.find { |pin| pin.name == "ai-flow" }.rule == head
    added.moved.map { |move| [move.name, move.from, move.rule] } == [["ai-flow", nil, head], ["cmake", nil, greatest]]
  end

  def gh_pin(version, sha, rule: nil)
    Dev::Deps::Dependency.new(
      name: "ai-flow", integration: :gh, group: :app, version:, hash: nil, source: sha,
      metadata: { "repo" => "d3mlabs/ai-flow", "commit" => sha }, rule:,
    )
  end

  test "a kept pin takes this resolution's provenance" do
    Given "a lock pin nobody needed, now needed by the xcode integration, with another declaration named"
    declarations = [declared("xcodes", tap: "xcodesorg/made", group: :app), declared("cmake")]
    previous = [formula("xcodes", version: "1.6.1", tap: "xcodesorg/made", group: :app, commit: OLD)]
    resolved = [formula("xcodes", version: "1.6.2", tap: "xcodesorg/made", group: :app, commit: NEW, metadata: { "needed_by" => ["xcode"] })]

    When "dev deps update cmake"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("cmake"))

    Then "the version, bottles, commit and source are the lock's; needed_by is today's"
    pin = outcome.pins.fetch(0)
    pin.version == "1.6.1"
    pin.metadata["tap_commit"] == OLD
    pin.source == "xcodesorg/made@#{OLD}"
    pin.metadata["platforms"] == previous.fetch(0).metadata["platforms"]
    pin.metadata["needed_by"] == ["xcode"]
  end

  test "a subset re-lock keeps the lock's pin for a declaration whose registry did not answer, and says so" do
    Given "dev#373: an image floor the host has no token for, beside the pip declaration being re-locked"
    floor = declared("cellbound-3d-linux", integration: :image, tap: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3", group: :app)
    declarations = [floor, declared("clang-format", integration: :pip, requirement: "= 18.1.8", group: :app)]
    floor_before = Dev::Deps::Dependency.new(name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3",
      hash: "SHA256=#{"a" * 64}", metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base" })
    previous = [floor_before, pip("clang-format", "17.0.6")]
    denied = Dev::Deps::OciRepository::AccessDeniedError.new("the registry refused gh's token")
    resolved = [Dev::Deps::Resolver::Unresolved.new(declaration: floor, error: denied), pip("clang-format", "18.1.8")]

    When "dev deps update clang-format"
    outcome = carryover.apply(declarations:, previous:, resolved:, unlock: update("clang-format"))

    Then "the floor is the lock's pin, in its place, reported with the registry's refusal; clang-format moves"
    versions(outcome.pins) == { "cellbound-3d-linux" => "ue5.8-3", "clang-format" => "18.1.8" }
    outcome.pins[0].equal?(floor_before)
    outcome.unreachable.map { |kept| [kept.pin, kept.error] } == [[floor_before, denied]]
    outcome.kept == []
  end

  test "a declaration whose registry did not answer propagates the failure when the re-lock needs today's answer: #{description}" do
    Given "an image floor the registry refuses"
    floor = declared("cellbound-3d-linux", integration: :image, tap: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3", group: :app)
    denied = Dev::Deps::OciRepository::AccessDeniedError.new("the registry refused gh's token")
    floor_before = Dev::Deps::Dependency.new(name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3",
      hash: "SHA256=#{"a" * 64}", metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base" })
    resolved = [Dev::Deps::Resolver::Unresolved.new(declaration: floor, error: denied)]

    When "carrying over"
    carryover.apply(declarations: [floor, declared("clang-format", integration: :pip)], previous: previous_for.call(floor_before), resolved:, unlock:)

    Then "the registry's own error surfaces"
    error = raises Dev::Deps::OciRepository::AccessDeniedError
    error.equal?(denied)

    Where
    description                               | unlock                                                    | previous_for
    "a bare update floats everything"         | Dev::Deps::UnlockSet.all                                  | ->(pin) { [pin] }
    "the floor is named"                      | Dev::Deps::UnlockSet.new(names: ["cellbound-3d-linux"])   | ->(pin) { [pin] }
    "the lock has no pin to keep"             | Dev::Deps::UnlockSet.new(names: ["clang-format"])         | ->(_pin) { [] }
  end

  test "a subset re-lock does not carry an image pin onto an edited floor its registry did not answer for: #{description}" do
    Given "a lock pin resolved from one floor, and a declaration that now names #{description}"
    floor = declared("cellbound-3d-linux", integration: :image, tap: edited, group: :app)
    floor_before = Dev::Deps::Dependency.new(name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3",
      hash: "SHA256=#{"a" * 64}", metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base" })
    failure = Dev::Deps::OciRepository::ReferenceError.new("#{edited.inspect} is not a floor reference")
    resolved = [Dev::Deps::Resolver::Unresolved.new(declaration: floor, error: failure)]

    When "dev deps update clang-format"
    carryover.apply(declarations: [floor, declared("clang-format", integration: :pip)], previous: [floor_before], resolved:,
      unlock: update("clang-format"))

    Then "the old digest is not kept behind a changed declaration: the repository's failure is the re-lock's"
    error = raises Dev::Deps::OciRepository::ReferenceError
    error.equal?(failure)

    Where
    description             | edited
    "another repository"    | "ghcr.io/typo/unreal-engine-build-base:ue5.8-3"
    "another tag"           | "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-4"
    "no reference at all"   | "unreal-engine-build-base"
  end

  test "a subset re-lock does not carry a pin its unanswered declaration moved to another group" do
    Given "a floor pin locked under :app, now declared under :build, its registry refusing"
    floor = declared("cellbound-3d-linux", integration: :image, tap: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3", group: :build)
    floor_before = Dev::Deps::Dependency.new(name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3",
      hash: "SHA256=#{"a" * 64}", metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base" })
    denied = Dev::Deps::OciRepository::AccessDeniedError.new("the registry refused gh's token")

    When "dev deps update clang-format"
    carryover.apply(declarations: [floor, declared("clang-format", integration: :pip)], previous: [floor_before],
      resolved: [Dev::Deps::Resolver::Unresolved.new(declaration: floor, error: denied)], unlock: update("clang-format"))

    Then
    raises Dev::Deps::OciRepository::AccessDeniedError
  end

  test "an unresolved need of a named integration propagates: the author asked for what it pulls in to float" do
    Given "dev deps update xcode, with brew unable to answer for xcodes"
    declarations = [declared("xcode", integration: :xcode, group: :app), declared("xcodes", tap: "xcodesorg/made", group: :app)]
    previous = [formula("xcodes", version: "1.6.1", tap: "xcodesorg/made", group: :app, commit: OLD, metadata: { "needed_by" => ["xcode"] })]
    outage = Dev::Deps::BrewRepository::BrewInfoError.new("brew info failed")
    resolved = [Dev::Deps::Resolver::Unresolved.new(declaration: declarations.fetch(1), error: outage, needed_by: ["xcode"])]

    When "carrying over"
    carryover.apply(declarations:, previous:, resolved:, unlock: update("xcode"))

    Then
    raises Dev::Deps::BrewRepository::BrewInfoError
  end

  test "a pin with no declaration behind it floats rather than being kept on a guess" do
    Given "a resolved formula no declaration or need accounts for, in a subset re-lock"
    previous = [formula("cmake", version: "4.4.4", commit: OLD)]
    resolved = [formula("cmake", version: "4.4.5", commit: NEW)]

    When "dev deps update jq, with no declaration for cmake"
    outcome = carryover.apply(declarations: [declared("jq")], previous:, resolved:, unlock: update("jq"))

    Then
    versions(outcome.pins) == { "cmake" => "4.4.5" }
    moves(outcome) == [["cmake", "4.4.4", "4.4.5", "declaration changed"]]
  end
end
