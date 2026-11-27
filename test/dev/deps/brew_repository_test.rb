# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_repository"
require "dev/provisioning_guard"
require "json"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRepositoryTest < Minitest::Test
  # The env every read query spawns brew under: no implicit auto-update,
  # whose API-cache refresh takes a lock only the prefix owner can write.
  READ_ENV = Dev::Deps::BrewRepository::READ_ENV

  # A bottle entry as both brew info and the formula API list it.
  def bottle_file(name, sha)
    { "cellar" => ":any", "url" => bottle_url(name, sha), "sha256" => sha }
  end

  def bottle_url(name, sha)
    "https://ghcr.io/v2/homebrew/core/#{name}/blobs/sha256:#{sha}"
  end

  def bottle_files(name, tags)
    tags.to_h { |tag| [tag, bottle_file(name, "sha-#{tag}")] }
  end

  def formula_json(name, stable:, sha: nil, versioned: [], tap: nil, tap_git_head: nil, bottles: nil)
    json = { "name" => name, "versions" => { "stable" => stable }, "versioned_formulae" => versioned }
    json["tap"] = tap if tap
    json["tap_git_head"] = tap_git_head if tap_git_head
    files = bottles ? bottle_files(name, bottles) : {}
    files["arm64_sonoma"] = bottle_file(name, sha) if sha
    json["bottle"] = { "stable" => { "files" => files } } unless files.empty?
    json
  end

  # The formula API's document for a core formula: its bottle list.
  #
  # @return [Net::HTTPOK]
  def api_response(bottles, name: "cmake")
    files = bottle_files(name, bottles)
    http_response("200", body: JSON.generate({ "bottle" => { "stable" => { "files" => files } } }))
  end

  # @param name [String] formula name
  # @return [URI] the formula API document a core formula's bottles are read from
  def formula_api_uri(name)
    URI("#{Dev::Deps::BrewRepository::FORMULA_API}/#{name}.json")
  end

  # `brew info --json=v1` for the given specs, as the repository spawns it.
  #
  # @return [Array]
  def brew_info_argv(*specs)
    [READ_ENV, "brew", "info", "--json=v1", *specs]
  end

  # `brew tap-info --json <tap>`, as the repository spawns it.
  #
  # @return [Array]
  def tap_info_argv(tap)
    [READ_ENV, "brew", "tap-info", "--json", tap]
  end

  # A brew query that answered with the given JSON.
  #
  # @return [Array(String, String, Process::Status)]
  def brew_json(document)
    [JSON.generate(document), "", exit_status(0)]
  end

  # `brew tap-info --json <tap>`: the tap's formula list (full names), or an
  # uninstalled tap's empty one.
  def tap_info_json(tap, names, installed: true)
    JSON.generate([{ "name" => tap, "installed" => installed, "formula_names" => names.map { |name| "#{tap}/#{name}" } }])
  end

  # What `brew tap-info --json` answers for an installed tap carrying `names`.
  #
  # @return [Array(String, String, Process::Status)]
  def tap_info(tap, names)
    [tap_info_json(tap, names), "", exit_status(0)]
  end

  test "find reports a family-less formula as a singleton universe" do
    Given "a formula with no versioned siblings"
    repository = Dev::Deps::BrewRepository.new

    When "finding the package"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "one version, publishing its one bottle as a platform with its artifact — no writer-side hash"
    _ * Open3.capture3(*brew_info_argv("cmake")) >> brew_json([formula_json("cmake", stable: "3.31.4", sha: "abc123def456")])
    package.versions.map(&:version) == ["3.31.4"]
    package.version("3.31.4").platforms == ["arm64_sonoma"]
    package.version("3.31.4").artifacts == {
      "arm64_sonoma" => Dev::Deps::Artifact.new(
        uri: bottle_url("cmake", "abc123def456"), digest: "SHA256=abc123def456",
      ),
    }
    package.version("3.31.4").digest.nil?
    package.version("3.31.4").source.nil?
    package.version("3.31.4").metadata == { "format" => "source" }
  end

  test "find reports a formula without bottles as a platform-less, artifact-less version" do
    Given "a formula brew only ever builds from source"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "tool"))

    Then "nothing published means nothing recorded; the image build compiles it"
    _ * Open3.capture3(*brew_info_argv("tool")) >> brew_json([formula_json("tool", stable: "2.0.0")])
    package.version("2.0.0").platforms == []
    package.version("2.0.0").artifacts == {}
    package.version("2.0.0").digest.nil?
    package.version("2.0.0").metadata == { "format" => "source" }
  end

  test "find enumerates the spec family — siblings' suffixes ride as facts, bare spec last" do
    Given "llvm with two versioned siblings"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "llvm"))

    Then "one version per spec; the bare spec sits last as the unconstrained pick"
    _ * Open3.capture3(*brew_info_argv("llvm")) >>
      brew_json([formula_json("llvm", stable: "21.1.0", sha: "llvm21", versioned: ["llvm@19", "llvm@18"])])
    _ * Open3.capture3(*brew_info_argv("llvm@19", "llvm@18")) >> brew_json([
      formula_json("llvm@19", stable: "19.1.7", sha: "llvm19"),
      formula_json("llvm@18", stable: "18.1.8", sha: "llvm18"),
    ])
    package.versions.map(&:version) == ["19.1.7", "18.1.8", "21.1.0"]
    package.version("18.1.8").metadata == { "version_suffix" => "18", "format" => "source" }
    package.version("18.1.8").artifacts["arm64_sonoma"].digest == "SHA256=llvm18"
    package.version("21.1.0").metadata == { "format" => "source" }
  end

  test "find skips head-only siblings without a stable version" do
    Given "a family whose sibling reports no stable version"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "tool"))

    Then "no stable version means not a version"
    _ * Open3.capture3(*brew_info_argv("tool")) >> brew_json([formula_json("tool", stable: "2.0.0", versioned: ["tool@head"])])
    _ * Open3.capture3(*brew_info_argv("tool@head")) >> brew_json([formula_json("tool@head", stable: nil)])
    package.versions.map(&:version) == ["2.0.0"]
  end

  test "find qualifies family queries with the tap and records it as a fact" do
    Given "a tapped formula"
    repository = Dev::Deps::BrewRepository.new

    When "finding with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"),
    )

    Then
    _ * Open3.capture3(*tap_info_argv("someorg/sometap")) >> tap_info("someorg/sometap", ["mytool", "othertool"])
    _ * Open3.capture3(*brew_info_argv("someorg/sometap/mytool")) >>
      brew_json([formula_json("mytool", stable: "1.2.0", sha: "mt12")])
    package.versions.map(&:version) == ["1.2.0"]
    package.version("1.2.0").metadata == { "tap" => "someorg/sometap", "format" => "source" }
  end

  test "find enumerates a tap formula's name@ family from the tap's own formula list, bare spec optional" do
    Given "a tap publishing one immutable formula per patch and no bare formula, beside look-alike names"
    repository = Dev::Deps::BrewRepository.new

    When "finding the bare name with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :ruby, name: "ruby", source: "d3mlabs/d3mlabs"),
    )

    Then "brew info reports an empty family for a tap formula, so the tap's list is the universe: every ruby@ file, nothing else"
    _ * Open3.capture3(*tap_info_argv("d3mlabs/d3mlabs")) >>
      tap_info("d3mlabs/d3mlabs", ["dev", "ruby-build", "ruby@4.0.5", "ruby@4.0.6", "ruby@4.0.9", "rubyfmt"])
    _ * Open3.capture3(*brew_info_argv("d3mlabs/d3mlabs/ruby@4.0.5", "d3mlabs/d3mlabs/ruby@4.0.6", "d3mlabs/d3mlabs/ruby@4.0.9")) >>
      brew_json([
        formula_json("ruby@4.0.5", stable: "4.0.5", tap: "d3mlabs/d3mlabs", tap_git_head: "532b8ac5"),
        formula_json("ruby@4.0.6", stable: "4.0.6", tap: "d3mlabs/d3mlabs", tap_git_head: "532b8ac5"),
        formula_json("ruby@4.0.9", stable: "4.0.9", tap: "d3mlabs/d3mlabs", tap_git_head: "532b8ac5", bottles: ["arm64_tahoe", "x86_64_linux"]),
      ])
    package.versions.map(&:version) == ["4.0.5", "4.0.6", "4.0.9"]
    package.version("4.0.9").metadata == {
      "tap" => "d3mlabs/d3mlabs", "version_suffix" => "4.0.9", "tap_commit" => "532b8ac5", "format" => "bottle",
    }
    package.version("4.0.5").metadata["format"] == "source"
  end

  test "find lists a tap family's bare spec last, as the unconstrained pick" do
    Given "a tap carrying a bare formula and a versioned sibling"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "tool", source: "someorg/sometap"),
    )

    Then
    _ * Open3.capture3(*tap_info_argv("someorg/sometap")) >> tap_info("someorg/sometap", ["tool", "tool@1"])
    _ * Open3.capture3(*brew_info_argv("someorg/sometap/tool@1", "someorg/sometap/tool")) >> brew_json([
      formula_json("tool@1", stable: "1.9.0", tap: "someorg/sometap"),
      formula_json("tool", stable: "2.0.0", tap: "someorg/sometap"),
    ])
    package.versions.map(&:version) == ["1.9.0", "2.0.0"]
    package.version("1.9.0").metadata["version_suffix"] == "1"
    package.version("2.0.0").metadata.key?("version_suffix") == false
  end

  test "find registers the declared tap and retries when it is not installed" do
    Given "a tapped formula on a machine that has never tapped it"
    repository = Dev::Deps::BrewRepository.new

    When "finding with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "xcodes", source: "xcodesorg/made"),
    )

    Then "the tap was registered and resolution succeeded on retry"
    1 * Open3.capture3(*tap_info_argv("xcodesorg/made")) >> tap_info("xcodesorg/made", ["xcodes"])
    # Mocha serves the latest declared match first, so the first answer is declared after the second.
    1 * Open3.capture3(*tap_info_argv("xcodesorg/made")) >> [tap_info_json("xcodesorg/made", [], installed: false), "", exit_status(0)]
    _ * Open3.capture3(READ_ENV, "brew", "tap", "xcodesorg/made") >> ["", "", exit_status(0)]
    _ * Open3.capture3(*brew_info_argv("xcodesorg/made/xcodes")) >> brew_json([formula_json("xcodes", stable: "1.6.2", sha: "xc123")])
    package.versions.map(&:version) == ["1.6.2"]
    package.version("1.6.2").metadata["tap"] == "xcodesorg/made"
  end

  test "find raises BrewInfoError when the tap carries neither the formula nor a name@ sibling" do
    Given "a tap without the formula"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"))

    Then "the error names the tap and the family it looked for"
    _ * Open3.capture3(*tap_info_argv("someorg/sometap")) >> tap_info("someorg/sometap", ["othertool"])
    error = raises Dev::Deps::BrewRepository::BrewInfoError
    error.message.include?("someorg/sometap")
    error.message.include?("mytool@*")
  end

  # --- A: the facts an image build pins ---------------------------------------

  test "find records the tap commit brew reports as the tap_commit fact" do
    Given "a tapped formula whose tap is checked out at a commit"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "wwise-cli", source: "d3mlabs/d3mlabs"),
    )

    Then "the commit rides the version as a fact the image build pins the tap to"
    _ * Open3.capture3(*tap_info_argv("d3mlabs/d3mlabs")) >> tap_info("d3mlabs/d3mlabs", ["wwise-cli"])
    _ * Open3.capture3(*brew_info_argv("d3mlabs/d3mlabs/wwise-cli")) >>
      brew_json([formula_json("wwise-cli", stable: "1.0.0", tap: "d3mlabs/d3mlabs", tap_git_head: "e5810c4f")])
    package.version("1.0.0").metadata["tap_commit"] == "e5810c4f"
    package.version("1.0.0").source == "d3mlabs/d3mlabs@e5810c4f"
  end

  test "find stamps a core formula's source as core at the commit brew reports" do
    Given "a core formula at a tap commit"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then
    _ * Open3.capture3(*brew_info_argv("cmake")) >>
      brew_json([formula_json("cmake", stable: "4.4.3", tap: "homebrew/core", tap_git_head: "3c67e3be")])
    1 * Net::HTTP.get_response(formula_api_uri("cmake")) >> api_response(["arm64_tahoe", "x86_64_linux"])
    package.version("4.4.3").source == "homebrew/core@3c67e3be"
  end

  test "source_at spells a tap commit the same way for a fresh version and for a pin read back: #{description}" do
    Expect
    Dev::Deps::BrewRepository.source_at(tap, "3c67e3be") == source

    Where
    description      | tap                 | source
    "core (no tap)"  | nil                 | "homebrew/core@3c67e3be"
    "a tapped one"   | "d3mlabs/d3mlabs"   | "d3mlabs/d3mlabs@3c67e3be"
  end

  test "refresh_index! runs brew update once the kill-switch allows it" do
    Given "a brew that updates cleanly, with the harness's guard lifted"
    guard = allow_provisioning
    repository = Dev::Deps::BrewRepository.new

    When "refreshing"
    repository.refresh_index!

    Then
    1 * Open3.capture3(READ_ENV, "brew", "update", "--quiet") >> ["", "", exit_status(0)]

    Cleanup
    restore_provisioning_guard(guard)
  end

  test "refresh_index! raises IndexRefreshError carrying brew's stderr when the update fails" do
    Given "a brew update that cannot reach its remote"
    guard = allow_provisioning
    repository = Dev::Deps::BrewRepository.new

    When "refreshing"
    repository.refresh_index!

    Then
    _ * Open3.capture3(READ_ENV, "brew", "update", "--quiet") >> ["", "fatal: unable to access github.com", exit_status(1)]
    error = raises Dev::Deps::BrewRepository::IndexRefreshError
    error.message == "brew update failed (fatal: unable to access github.com)"

    Cleanup
    restore_provisioning_guard(guard)
  end

  test "refresh_index! is refused by the test harness's kill-switch: it writes the prefix like an install" do
    Given "the guard armed, as every test has it"
    repository = Dev::Deps::BrewRepository.new

    When "refreshing"
    repository.refresh_index!

    Then
    0 * Open3.capture3
    error = raises Dev::ProvisioningGuard::ForbiddenError
    error.message.include?("BrewRepository#refresh_index!")
  end

  test "find records how the image build gets a tap formula from its bottle block: #{description}" do
    Given "a tap formula (brew info reads it from source, so every bottle it has is listed)"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"),
    )

    Then "every bottle is a platform, in a stable order; format is bottle only when the image platform has one"
    _ * Open3.capture3(*tap_info_argv("someorg/sometap")) >> tap_info("someorg/sometap", ["mytool"])
    _ * Open3.capture3(*brew_info_argv("someorg/sometap/mytool")) >>
      brew_json([formula_json("mytool", stable: "1.2.0", tap: "someorg/sometap", bottles: bottles)])
    package.version("1.2.0").platforms == platforms
    package.version("1.2.0").artifacts.keys == platforms
    package.version("1.2.0").metadata["format"] == format

    Where
    description              | bottles                            | platforms                        | format
    "image bottle present"   | ["x86_64_linux", "arm64_tahoe"]    | ["arm64_tahoe", "x86_64_linux"]  | "bottle"
    "mac-only bottles"       | ["arm64_tahoe", "arm64_sequoia"]   | ["arm64_sequoia", "arm64_tahoe"] | "source"
    "no bottle block"        | []                                 | []                               | "source"
  end

  test "find asks the formula API for a core formula's bottles, since brew info lists only this machine's" do
    Given "a core formula whose local info carries one bottle, and the API listing the image platform too"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "the API's bottle list is the version's platforms and artifacts, and decides the format — this machine's bottle is not special"
    _ * Open3.capture3(*brew_info_argv("cmake")) >>
      brew_json([formula_json("cmake", stable: "4.4.3", sha: "mac", tap: "homebrew/core", tap_git_head: "3c67e3be")])
    1 * Net::HTTP.get_response(formula_api_uri("cmake")) >> api_response(["arm64_tahoe", "x86_64_linux"])
    package.version("4.4.3").metadata == { "tap_commit" => "3c67e3be", "format" => "bottle" }
    package.version("4.4.3").platforms == ["arm64_tahoe", "x86_64_linux"]
    package.version("4.4.3").artifacts == {
      "arm64_tahoe" => Dev::Deps::Artifact.new(uri: bottle_url("cmake", "sha-arm64_tahoe"), digest: "SHA256=sha-arm64_tahoe"),
      "x86_64_linux" => Dev::Deps::Artifact.new(uri: bottle_url("cmake", "sha-x86_64_linux"), digest: "SHA256=sha-x86_64_linux"),
    }
    package.version("4.4.3").digest.nil?
  end

  test "find reads a core formula's bottles from formulae.brew.sh's formula API" do
    Given "a core formula and the formula API answering for it"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "the formula's JSON document is what gets fetched"
    _ * Open3.capture3(*brew_info_argv("cmake")) >>
      brew_json([formula_json("cmake", stable: "4.4.3", tap: "homebrew/core", tap_git_head: "3c67e3be")])
    1 * Net::HTTP.get_response(URI("https://formulae.brew.sh/api/formula/cmake.json")) >> api_response(["x86_64_linux"])
    package.version("4.4.3").metadata["format"] == "bottle"
  end

  test "find raises FormulaApiError when the formula API cannot be read for a core formula" do
    Given "a core formula and an API that answers with an error"
    repository = Dev::Deps::BrewRepository.new

    When "finding"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then
    _ * Open3.capture3(*brew_info_argv("cmake")) >> brew_json([formula_json("cmake", stable: "4.4.3", tap: "homebrew/core")])
    1 * Net::HTTP.get_response(formula_api_uri("cmake")) >> http_response("503")
    error = raises Dev::Deps::BrewRepository::FormulaApiError
    error.message.include?("cmake")
    error.message.include?("503")
  end

  test "find raises BrewInfoError when brew info fails" do
    Given "a formula that brew info cannot resolve"
    repository = Dev::Deps::BrewRepository.new

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "nonexistent"))

    Then
    _ * Open3.capture3(*brew_info_argv("nonexistent")) >> ["", "Error: No available formula", exit_status(1)]
    raises Dev::Deps::BrewRepository::BrewInfoError
  end

  # --- shared prefixes: reads never write -------------------------------------

  test "find spawns every brew query with HOMEBREW_NO_AUTO_UPDATE=1, so a non-owner uid can resolve on a shared prefix" do
    Given "a tap formula on a machine that has never tapped it — every brew the repository runs, in one resolution"
    repository = Dev::Deps::BrewRepository.new

    When "finding with the tap on the id"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "xcodes", source: "xcodesorg/made"))

    Then "tap and info carry the env (tap-info above answers only under it): brew's implicit auto-update takes a lock under the prefix owner's var/homebrew/locks"
    1 * Open3.capture3(*tap_info_argv("xcodesorg/made")) >> tap_info("xcodesorg/made", ["xcodes"])
    # Mocha serves the latest declared match first, so the first answer is declared after the second.
    1 * Open3.capture3(*tap_info_argv("xcodesorg/made")) >> [tap_info_json("xcodesorg/made", [], installed: false), "", exit_status(0)]
    1 * Open3.capture3(READ_ENV, "brew", "tap", "xcodesorg/made") >> ["", "", exit_status(0)]
    1 * Open3.capture3(READ_ENV, "brew", "info", "--json=v1", "xcodesorg/made/xcodes") >>
      [JSON.generate([formula_json("xcodes", stable: "1.6.2")]), "", exit_status(0)]
  end
end
