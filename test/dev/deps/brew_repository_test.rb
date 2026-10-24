# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRepositoryTest < Minitest::Test
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

  def api_response(bottles, name: "cmake")
    files = bottle_files(name, bottles)
    response = stub(body: JSON.generate({ "bottle" => { "stable" => { "files" => files } } }))
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    response.stubs(:is_a?).with(Net::HTTPResponse).returns(true)
    response
  end

  def stub_brew_info(specs, infos)
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", *specs)
         .returns([JSON.generate(infos), "", stub(success?: true)])
  end

  # `brew tap-info --json <tap>`: the tap's formula list (full names), or an
  # uninstalled tap's empty one.
  def tap_info_json(tap, names, installed: true)
    JSON.generate([{ "name" => tap, "installed" => installed, "formula_names" => names.map { |name| "#{tap}/#{name}" } }])
  end

  def stub_tap_info(tap, names)
    Open3.stubs(:capture3)
         .with("brew", "tap-info", "--json", tap)
         .returns([tap_info_json(tap, names), "", stub(success?: true)])
  end

  test "find reports a family-less formula as a singleton universe" do
    Given "a formula with no versioned siblings"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["cmake"], [formula_json("cmake", stable: "3.31.4", sha: "abc123def456")])

    When "finding the package"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "one version, publishing its one bottle as a platform with its artifact — no writer-side hash"
    package.versions.map(&:version) == ["3.31.4"]
    package.version("3.31.4").platforms == ["arm64_sonoma"]
    package.version("3.31.4").artifacts == {
      "arm64_sonoma" => Dev::Deps::Artifact.new(
        uri: bottle_url("cmake", "abc123def456"), digest: "SHA256=abc123def456",
      ),
    }
    package.version("3.31.4").digest.nil?
    package.version("3.31.4").metadata == { "format" => "source" }
  end

  test "find reports a formula without bottles as a platform-less, artifact-less version" do
    Given "a formula brew only ever builds from source"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["tool"], [formula_json("tool", stable: "2.0.0")])

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "tool"))

    Then "nothing published means nothing recorded; the image build compiles it"
    package.version("2.0.0").platforms == []
    package.version("2.0.0").artifacts == {}
    package.version("2.0.0").digest.nil?
    package.version("2.0.0").metadata == { "format" => "source" }
  end

  test "find enumerates the spec family — siblings' suffixes ride as facts, bare spec last" do
    Given "llvm with two versioned siblings"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["llvm"],
      [formula_json("llvm", stable: "21.1.0", sha: "llvm21", versioned: ["llvm@19", "llvm@18"])])
    stub_brew_info(["llvm@19", "llvm@18"], [
      formula_json("llvm@19", stable: "19.1.7", sha: "llvm19"),
      formula_json("llvm@18", stable: "18.1.8", sha: "llvm18"),
    ])

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "llvm"))

    Then "one version per spec; the bare spec sits last as the unconstrained pick"
    package.versions.map(&:version) == ["19.1.7", "18.1.8", "21.1.0"]
    package.version("18.1.8").metadata == { "version_suffix" => "18", "format" => "source" }
    package.version("18.1.8").artifacts["arm64_sonoma"].digest == "SHA256=llvm18"
    package.version("21.1.0").metadata == { "format" => "source" }
  end

  test "find skips head-only siblings without a stable version" do
    Given "a family whose sibling reports no stable version"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["tool"], [formula_json("tool", stable: "2.0.0", versioned: ["tool@head"])])
    stub_brew_info(["tool@head"], [formula_json("tool@head", stable: nil)])

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "tool"))

    Then "no stable version means not a version"
    package.versions.map(&:version) == ["2.0.0"]
  end

  test "find qualifies family queries with the tap and records it as a fact" do
    Given "a tapped formula"
    repository = Dev::Deps::BrewRepository.new
    stub_tap_info("someorg/sometap", ["mytool", "othertool"])
    stub_brew_info(["someorg/sometap/mytool"],
      [formula_json("mytool", stable: "1.2.0", sha: "mt12")])

    When "finding with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"),
    )

    Then
    package.versions.map(&:version) == ["1.2.0"]
    package.version("1.2.0").metadata == { "tap" => "someorg/sometap", "format" => "source" }
  end

  test "find enumerates a tap formula's name@ family from the tap's own formula list, bare spec optional" do
    Given "a tap publishing one immutable formula per patch and no bare formula, beside look-alike names"
    repository = Dev::Deps::BrewRepository.new
    stub_tap_info("d3mlabs/d3mlabs", ["dev", "ruby-build", "ruby@4.0.5", "ruby@4.0.6", "ruby@4.0.9", "rubyfmt"])
    stub_brew_info(["d3mlabs/d3mlabs/ruby@4.0.5", "d3mlabs/d3mlabs/ruby@4.0.6", "d3mlabs/d3mlabs/ruby@4.0.9"], [
      formula_json("ruby@4.0.5", stable: "4.0.5", tap: "d3mlabs/d3mlabs", tap_git_head: "532b8ac5"),
      formula_json("ruby@4.0.6", stable: "4.0.6", tap: "d3mlabs/d3mlabs", tap_git_head: "532b8ac5"),
      formula_json("ruby@4.0.9", stable: "4.0.9", tap: "d3mlabs/d3mlabs", tap_git_head: "532b8ac5", bottles: ["arm64_tahoe", "x86_64_linux"]),
    ])

    When "finding the bare name with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :ruby, name: "ruby", source: "d3mlabs/d3mlabs"),
    )

    Then "brew info reports an empty family for a tap formula, so the tap's list is the universe: every ruby@ file, nothing else"
    package.versions.map(&:version) == ["4.0.5", "4.0.6", "4.0.9"]
    package.version("4.0.9").metadata == {
      "tap" => "d3mlabs/d3mlabs", "version_suffix" => "4.0.9", "tap_commit" => "532b8ac5", "format" => "bottle",
    }
    package.version("4.0.5").metadata["format"] == "source"
  end

  test "find lists a tap family's bare spec last, as the unconstrained pick" do
    Given "a tap carrying a bare formula and a versioned sibling"
    repository = Dev::Deps::BrewRepository.new
    stub_tap_info("someorg/sometap", ["tool", "tool@1"])
    stub_brew_info(["someorg/sometap/tool@1", "someorg/sometap/tool"], [
      formula_json("tool@1", stable: "1.9.0", tap: "someorg/sometap"),
      formula_json("tool", stable: "2.0.0", tap: "someorg/sometap"),
    ])

    When "finding"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "tool", source: "someorg/sometap"),
    )

    Then
    package.versions.map(&:version) == ["1.9.0", "2.0.0"]
    package.version("1.9.0").metadata["version_suffix"] == "1"
    package.version("2.0.0").metadata.key?("version_suffix") == false
  end

  test "find registers the declared tap and retries when it is not installed" do
    Given "a tapped formula on a machine that has never tapped it"
    repository = Dev::Deps::BrewRepository.new
    Open3.stubs(:capture3)
         .with("brew", "tap-info", "--json", "xcodesorg/made")
         .returns([tap_info_json("xcodesorg/made", [], installed: false), "", stub(success?: true)])
         .then.returns([tap_info_json("xcodesorg/made", ["xcodes"]), "", stub(success?: true)])
    Open3.stubs(:capture3)
         .with("brew", "tap", "xcodesorg/made")
         .returns(["", "", stub(success?: true)])
    stub_brew_info(["xcodesorg/made/xcodes"], [formula_json("xcodes", stable: "1.6.2", sha: "xc123")])

    When "finding with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "xcodes", source: "xcodesorg/made"),
    )

    Then "the tap was registered and resolution succeeded on retry"
    package.versions.map(&:version) == ["1.6.2"]
    package.version("1.6.2").metadata["tap"] == "xcodesorg/made"
  end

  test "find raises BrewInfoError when the tap carries neither the formula nor a name@ sibling" do
    Given "a tap without the formula"
    repository = Dev::Deps::BrewRepository.new
    stub_tap_info("someorg/sometap", ["othertool"])

    When "finding"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"))

    Then "the error names the tap and the family it looked for"
    error = raises Dev::Deps::BrewRepository::BrewInfoError
    error.message.include?("someorg/sometap")
    error.message.include?("mytool@*")
  end

  # --- A: the facts an image build pins ---------------------------------------

  test "find records the tap commit brew reports as the tap_commit fact" do
    Given "a tapped formula whose tap is checked out at a commit"
    repository = Dev::Deps::BrewRepository.new
    stub_tap_info("d3mlabs/d3mlabs", ["wwise-cli"])
    stub_brew_info(["d3mlabs/d3mlabs/wwise-cli"],
      [formula_json("wwise-cli", stable: "1.0.0", tap: "d3mlabs/d3mlabs", tap_git_head: "e5810c4f")])

    When "finding"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "wwise-cli", source: "d3mlabs/d3mlabs"),
    )

    Then "the commit rides the version as a fact the image build pins the tap to"
    package.version("1.0.0").metadata["tap_commit"] == "e5810c4f"
  end

  test "find records how the image build gets a tap formula from its bottle block: #{description}" do
    Given "a tap formula (brew info reads it from source, so every bottle it has is listed)"
    repository = Dev::Deps::BrewRepository.new
    stub_tap_info("someorg/sometap", ["mytool"])
    stub_brew_info(["someorg/sometap/mytool"],
      [formula_json("mytool", stable: "1.2.0", tap: "someorg/sometap", bottles: bottles)])

    When "finding"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"),
    )

    Then "every bottle is a platform, in a stable order; format is bottle only when the image platform has one"
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
    stub_brew_info(["cmake"],
      [formula_json("cmake", stable: "4.4.3", sha: "mac", tap: "homebrew/core", tap_git_head: "3c67e3be")])
    repository.stubs(:get_formula_api).with("cmake").returns(api_response(["arm64_tahoe", "x86_64_linux"]))

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "the API's bottle list is the version's platforms and artifacts, and decides the format — this machine's bottle is not special"
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
    stub_brew_info(["cmake"], [formula_json("cmake", stable: "4.4.3", tap: "homebrew/core", tap_git_head: "3c67e3be")])

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "the formula's JSON document is what gets fetched"
    1 * Net::HTTP.get_response(URI("https://formulae.brew.sh/api/formula/cmake.json")) >> api_response(["x86_64_linux"])
    package.version("4.4.3").metadata["format"] == "bottle"
  end

  test "find raises FormulaApiError when the formula API cannot be read for a core formula" do
    Given "a core formula and an API that answers with an error"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["cmake"], [formula_json("cmake", stable: "4.4.3", tap: "homebrew/core")])
    response = stub(code: "503")
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(false)
    repository.stubs(:get_formula_api).with("cmake").returns(response)

    When "finding"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then
    error = raises Dev::Deps::BrewRepository::FormulaApiError
    error.message.include?("cmake")
    error.message.include?("503")
  end

  test "find raises BrewInfoError when brew info fails" do
    Given "a formula that brew info cannot resolve"
    repository = Dev::Deps::BrewRepository.new
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "nonexistent")
         .returns(["", "Error: No available formula", stub(success?: false)])

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "nonexistent"))

    Then
    raises Dev::Deps::BrewRepository::BrewInfoError
  end
end
