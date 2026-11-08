# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_repository"
require "dev/lifecycle"
require "support/alpakit_fixtures"
require "support/fake_ficsit_client"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitRepositoryTest < Minitest::Test
  include AlpakitFixtures
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 8, 12, 0, 0)
  TOKEN = "smr-api-key"

  def setup
    @root = Pathname(Dir.mktmpdir("ficsit-repository-"))
    @scratch = @root / "store" / ".ficsit"
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # @param client [FakeFicsitClient]
  # @return [Dev::Deps::FicsitRepository] with a key in hand and a sleeper that only records
  def repository(client, part_size: Dev::Deps::FicsitRepository::PART_SIZE, sleeps: [])
    Dev::Deps::FicsitRepository.new(client:, api_key: -> { TOKEN }, sleeper: ->(seconds) { sleeps << seconds }, part_size:)
  end

  def find(client, mod_reference)
    Dev::Deps::FicsitRepository.new(client:).find(Dev::Deps::PackageId.new(integration: :ficsit, name: mod_reference))
  end

  def mod(versions, id: "abc123", mod_reference: "SML")
    { "GetMod" => { "getModByReference" => { "id" => id, "name" => mod_reference, "mod_reference" => mod_reference, "versions" => versions } } }
  end

  # A shipment of a per-target Alpakit zip in the store, as `deploy` hands one over.
  def shipment(build_name, zip)
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.13", now: NOON),
      build: build(build_name),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: zip.basename.to_s,
      archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir: zip.dirname, manifest:))
  end

  # snappy's shape over the fixtures' targets: the Steam and Epic clients are two Windows plugins, the server a LinuxServer one.
  def snappy_shipments
    [
      shipment("cellbound-3d-win64-release", alpakit_zip(@root, "cellbound-3d-win64-release", mod_reference: "Snappy", target: "Windows",
        binaries: { "Binaries/Win64/FactoryGameSteam-Snappy-Win64-Shipping.dll" => "steam" })),
      shipment("cellbound-3d-steamworks-win64-release", alpakit_zip(@root, "cellbound-3d-steamworks-win64-release", mod_reference: "Snappy",
        target: "Windows", binaries: { "Binaries/Win64/FactoryGameEGS-Snappy-Win64-Shipping.dll" => "egs" })),
      shipment("cellbound-3d-server-linux64-release", alpakit_zip(@root, "cellbound-3d-server-linux64-release", mod_reference: "Snappy",
        target: "LinuxServer", binaries: { "Binaries/Linux/libFactoryServer-Snappy-Linux-Shipping.so" => "so" })),
    ]
  end

  def channel
    Dev::Lifecycle::Channel.new(
      name: "ficsit", desc: "SMR", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "ficsit"),
    )
  end

  # The answers of a whole successful upload, processed on the second poll.
  def upload_answers(processed_after: 2)
    polls = 0
    {
      "GetModId" => { "getModByReference" => { "id" => "mod-1" } },
      "CreateVersion" => { "createVersion" => "upload-9" },
      "UploadVersionPart" => { "uploadVersionPart" => true },
      "FinalizeCreateVersion" => { "finalizeCreateVersion" => true },
      "CheckVersionUploadState" => lambda do |_variables, _file|
        polls += 1
        state = polls >= processed_after ? { "auto_approved" => true, "version" => { "id" => "upload-9", "version" => "1.2.0" } } : nil
        { "checkVersionUploadState" => state }
      end,
    }
  end

  test "find reports every published version with its universe facts" do
    Given "a mod with two versions on ficsit.app"
    client = FakeFicsitClient.new(mod([
      {
        "id" => "ver2", "version" => "2.5.0", "game_version" => ">=491125",
        "targets" => [{ "targetName" => "Windows", "hash" => "deadbeef", "size" => 500_000, "link" => "/v1/version/ver2/Windows/download" }],
        "dependencies" => [
          { "mod_id" => "SML", "condition" => "^3.12.0", "optional" => false },
          { "mod_id" => "OptionalMod", "condition" => ">=1.0", "optional" => true },
        ],
      },
      {
        "id" => "ver1", "version" => "2.4.0", "game_version" => ">=400000",
        "targets" => [{ "targetName" => "Windows", "hash" => "cafebabe", "size" => 400_000 }],
        "dependencies" => [],
      },
    ], mod_reference: "AreaActions"))

    When "finding the package"
    package = find(client, "AreaActions")

    Then "the whole universe is reported, facts attached, nothing projected; the query went out anonymous"
    package.versions.map(&:version) == ["2.5.0", "2.4.0"]
    latest = package.version("2.5.0")
    latest.platforms == ["Windows"]
    latest.digest.nil?
    latest.artifacts["Windows"].uri == "https://api.ficsit.app/v1/version/ver2/Windows/download"
    latest.artifacts["Windows"].digest == "SHA256=deadbeef"
    latest.declarations == Dev::Deps::Declarations::Resolved.new([
      Dev::Deps::Declaration.new(name: "SML", integration: :ficsit, constraint: { "version" => "^3.12.0" }),
    ])
    latest.metadata == { "mod_id" => "abc123", "game_version" => ">=491125" }
    package.version("2.4.0").artifacts["Windows"].digest == "SHA256=cafebabe"
    client.calls.map { |call| [call.operation, call.variables, call.token] } == [["GetMod", { modReference: "AreaActions" }, nil]]
  end

  test "find reports every target's artifact — projection is the Resolver's job" do
    Given "a mod with Windows and LinuxServer targets"
    client = FakeFicsitClient.new(mod([{
      "id" => "ver1", "version" => "3.12.0", "game_version" => ">=491125",
      "targets" => [
        { "targetName" => "Windows", "hash" => "winhash", "size" => 100, "link" => "/v1/version/ver1/Windows/download" },
        { "targetName" => "LinuxServer", "hash" => "linuxhash", "size" => 200, "link" => "/v1/version/ver1/LinuxServer/download" },
      ],
      "dependencies" => [],
    }]))

    When "finding"
    version = find(client, "SML").version("3.12.0")

    Then "both targets are artifacts with their own digests; no install facts minted here"
    version.platforms.sort == ["LinuxServer", "Windows"]
    version.artifacts["Windows"].digest == "SHA256=winhash"
    version.artifacts["LinuxServer"].digest == "SHA256=linuxhash"
    !version.metadata.key?("platforms")
    !version.metadata.key?("target")
  end

  test "find raises ModNotFoundError, a PackageNotFoundError, for unknown mods" do
    Given "a repository returning null mod data"
    client = FakeFicsitClient.new({ "GetMod" => { "getModByReference" => nil } })

    When "finding a nonexistent mod"
    find(client, "NonExistentMod")

    Then
    e = raises Dev::Deps::FicsitRepository::ModNotFoundError
    e.is_a?(Dev::Deps::Repository::PackageNotFoundError)
  end

  test "find reports a mod with no versions as an empty package" do
    Given "a mod with empty versions"
    client = FakeFicsitClient.new(mod([], mod_reference: "EmptyMod"))

    When "finding the package"
    package = find(client, "EmptyMod")

    Then "an empty universe is a fact, not an error"
    package.empty?
  end

  test "find builds the artifact link from the version id when link is absent, and keeps an absolute one" do
    Given "one target without a link field, one with an absolute link"
    client = FakeFicsitClient.new(mod([{
      "id" => "ver1", "version" => "3.12.0", "game_version" => ">=491125",
      "targets" => [
        { "targetName" => "LinuxServer", "hash" => "linuxhash", "size" => 200 },
        { "targetName" => "Windows", "hash" => "winhash", "size" => 100, "link" => "https://cdn.example/SML-Windows.zip" },
      ],
      "dependencies" => [],
    }]))

    When "finding"
    version = find(client, "SML").version("3.12.0")

    Then "the missing link falls back to the /v1/version/<id>/<target>/download shape"
    version.artifacts["LinuxServer"].uri == "https://api.ficsit.app/v1/version/ver1/LinuxServer/download"
    version.artifacts["Windows"].uri == "https://cdn.example/SML-Windows.zip"
  end

  test "find reports a targetless version with a nil digest" do
    Given "a mod version with no targets"
    client = FakeFicsitClient.new(mod([{ "id" => "ver1", "version" => "1.0.0", "game_version" => ">=491125", "targets" => [], "dependencies" => [] }],
      mod_reference: "NoTargetMod"))

    When "finding the package"
    package = find(client, "NoTargetMod")

    Then "no published bytes, no integrity fact"
    package.version("1.0.0").digest.nil?
  end

  test "find lets the client's ApiError through" do
    Given "a client whose answer is SMR's refusal"
    client = FakeFicsitClient.new({ "GetMod" => ->(_variables, _file) { raise Dev::Deps::FicsitClient::ApiError, "something went wrong" } })

    When "finding triggers an API error"
    find(client, "BadMod")

    Then
    raises Dev::Deps::FicsitClient::ApiError
  end

  test "publish merges the per-target zips, uploads the multi-target zip in parts and finalizes as #{stability} on the #{track} track" do
    Given "snappy's three shipments and an SMR that processes the upload on the second poll"
    client = FakeFicsitClient.new(upload_answers)
    sleeps = []
    repo = repository(client, part_size: 1000, sleeps:)
    shipments = snappy_shipments

    When
    receipt = repo.publish(shipments, channel:, track:, scratch: @scratch)

    Then "the receipt names the mod, its targets, the stability and the version SMR made"
    receipt == Dev::Lifecycle::Receipt.new(summary: "ficsit: Snappy (Windows, LinuxServer) → #{stability}, version 1.2.0 (upload-9), auto-approved")

    merged = @scratch / "Snappy.zip"
    merged.file?
    zip_entries(merged).include?("Windows/Binaries/Win64/FactoryGameEGS-Snappy-Win64-Shipping.dll")
    zip_entries(merged).include?("LinuxServer/Snappy.uplugin")

    calls = client.calls
    calls.map(&:operation) == ["GetModId", "CreateVersion", *["UploadVersionPart"] * (merged.size.to_f / 1000).ceil, "FinalizeCreateVersion",
                               "CheckVersionUploadState", "CheckVersionUploadState"]
    calls.all? { |call| call.token == TOKEN }
    calls[0].variables == { modReference: "Snappy" }
    calls[1].variables == { modId: "mod-1" }

    parts = client.calls_of("UploadVersionPart")
    parts.map { |part| part.variables[:part] } == (1..parts.size).to_a
    parts.all? { |part| part.variables.slice(:modId, :versionId) == { modId: "mod-1", versionId: "upload-9" } && part.filename == "Snappy.zip" }
    parts.map(&:file).join == merged.binread
    parts[0...-1].all? { |part| part.file.bytesize == 1000 }

    finalize = client.calls_of("FinalizeCreateVersion").first
    finalize.variables[:modId] == "mod-1"
    finalize.variables[:versionId] == "upload-9"
    finalize.variables[:version][:stability] == stability
    finalize.variables[:version][:changelog] == [
      "dev deploy ficsit (#{track} track)",
      "- cellbound-3d-win64-release (1.2.0+3f2a1c9d8e7b)",
      "- cellbound-3d-steamworks-win64-release (1.2.0+3f2a1c9d8e7b)",
      "- cellbound-3d-server-linux64-release (1.2.0+3f2a1c9d8e7b)",
    ].join("\n")

    client.calls_of("CheckVersionUploadState").map(&:variables).uniq == [{ modId: "mod-1", versionId: "upload-9" }]
    sleeps == [Dev::Deps::FicsitRepository::POLL_INTERVAL_SECONDS]

    Where
    track                          | stability
    Dev::Lifecycle::Track::Testing | "beta"
    Dev::Lifecycle::Track::Live    | "release"
  end

  test "publish reports a version SMR holds for approval as such" do
    Given "an SMR whose first poll already carries the version, not auto-approved"
    answers = upload_answers(processed_after: 1)
    answers["CheckVersionUploadState"] = { "checkVersionUploadState" => { "auto_approved" => false, "version" => { "id" => "upload-9", "version" => "1.2.0" } } }
    client = FakeFicsitClient.new(answers)
    sleeps = []

    When
    receipt = repository(client, sleeps:).publish(snappy_shipments.first(1), channel:, track: Dev::Lifecycle::Track::Testing, scratch: @scratch)

    Then "one part for a small zip, no sleep before the first poll"
    receipt.summary == "ficsit: Snappy (Windows) → beta, version 1.2.0 (upload-9), awaiting approval"
    client.calls_of("UploadVersionPart").size == 1
    sleeps == []
  end

  test "publish refuses when no mod on ficsit.app has the plugins' reference, before anything is uploaded" do
    Given
    client = FakeFicsitClient.new(upload_answers.merge("GetModId" => { "getModByReference" => nil }))

    When
    repository(client).publish(snappy_shipments, channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    e = raises Dev::Deps::FicsitRepository::ModNotFoundError
    e.message == "mod Snappy not found on ficsit.app"
    client.calls.map(&:operation) == ["GetModId"]
  end

  test "publish refuses a part SMR answers false to" do
    Given
    client = FakeFicsitClient.new(upload_answers.merge("UploadVersionPart" => { "uploadVersionPart" => false }))

    When
    repository(client).publish(snappy_shipments, channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    e = raises Dev::Deps::FicsitRepository::UploadRefusedError
    e.message == "ficsit.app refused part 1 of Snappy.zip"
    client.calls_of("FinalizeCreateVersion").empty?
  end

  test "publish refuses a finalization SMR answers false to" do
    Given
    client = FakeFicsitClient.new(upload_answers.merge("FinalizeCreateVersion" => { "finalizeCreateVersion" => false }))

    When
    repository(client).publish(snappy_shipments, channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    e = raises Dev::Deps::FicsitRepository::UploadRefusedError
    e.message == "ficsit.app refused to finalize upload upload-9"
    client.calls_of("CheckVersionUploadState").empty?
  end

  test "publish gives up when SMR never finishes processing, having waited the frontend's schedule" do
    Given "an SMR whose upload state never carries a version"
    client = FakeFicsitClient.new(upload_answers.merge("CheckVersionUploadState" => { "checkVersionUploadState" => nil }))
    sleeps = []

    When
    repository(client, sleeps:).publish(snappy_shipments, channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    e = raises Dev::Deps::FicsitRepository::ProcessingTimedOutError
    e.message.include?("within 600s")
    client.calls_of("CheckVersionUploadState").size == 60
    sleeps == [10] * 59
  end

  test "publish surfaces SMR's processing failure in its words" do
    Given "an SMR that rejects the upload while processing (a version that already exists)"
    answers = upload_answers.merge("CheckVersionUploadState" => ->(_variables, _file) { raise Dev::Deps::FicsitClient::ApiError, "version 1.2.0 already exists" })
    client = FakeFicsitClient.new(answers)

    When
    repository(client).publish(snappy_shipments, channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    e = raises Dev::Deps::FicsitClient::ApiError
    e.message == "version 1.2.0 already exists"
  end

  test "publish does not call the API when the shipments do not merge" do
    Given "two Windows builds whose cooked content differs"
    client = FakeFicsitClient.new(upload_answers)
    shipments = [
      shipment("cellbound-3d-win64-release", alpakit_zip(@root, "a", mod_reference: "Snappy", target: "Windows", pak: "cook A")),
      shipment("cellbound-3d-steamworks-win64-release", alpakit_zip(@root, "b", mod_reference: "Snappy", target: "Windows", pak: "cook B")),
    ]

    When
    repository(client).publish(shipments, channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    raises Dev::Deps::MultiTargetPluginMerger::ConflictingFileError
    client.calls.empty?
  end

  test "the default API key is the ficsit namespace's api_key, FICSIT_API_KEY in the env, and the publisher reads as its channel" do
    Expect "the credential a `dev cred get ficsit api_key` resolves (the env wins, so nothing prompts here)"
    key = begin
      ENV["FICSIT_API_KEY"] = "from-env"
      Dev::Deps::FicsitRepository::DEFAULT_API_KEY.call
    ensure
      ENV.delete("FICSIT_API_KEY")
    end
    key == "from-env"
    Dev::Deps::FicsitRepository.new.to_s == "ficsit"
    Dev::Deps::FicsitRepository.new.is_a?(Dev::Lifecycle::Publisher)
  end
end
