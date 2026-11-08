# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ghcr_publisher"
require "dev/lifecycle"
require "support/fake_container_engine"
require "support/fake_registry_login"
require "support/release_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GhcrPublisherTest < Minitest::Test
  include ReleaseFixtures

  IMAGE = "ghcr.io/d3mlabs/unreal-engine-build-base"

  def setup
    @root = Pathname(Dir.mktmpdir("ghcr-publisher-"))
    @login = FakeRegistryLogin.new
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # An engine whose `docker load` answers per archive basename, and whose
  # runs succeed unless told which docker args to refuse.
  #
  # @param loads [Hash{String => String}] archive basename → `docker load` stdout
  # @param refuse [Array<String>, nil] the docker args of the one run to fail
  # @return [FakeContainerEngine]
  def engine_loading(loads, refuse: nil)
    load_output = ->(args) { args.first == "load" ? loads.fetch(File.basename(args.last), "") : "" }
    refuses = ->(docker_args) { docker_args != refuse }
    FakeContainerEngine.new(capture_result: load_output, &refuses)
  end

  # @return [Dev::Lifecycle::Shipment] a release's archive of the gem-shaped target, as an image tarball
  def release_shipment(build_name, version: "ue5.8-3")
    archive = @root / "releases" / "#{build_name}-#{version}.tar"
    archive.dirname.mkpath
    archive.write("image bytes of #{build_name}")
    entry = release_entry(build_name, bytes: archive.read, version: "1.2.0", extension: "tar")
    Dev::Lifecycle::Shipment.of_release(entry, archive:, tag: Dev::Lifecycle::ReleaseTag.new(version), sha: RELEASE_SHA)
  end

  # @return [Dev::Lifecycle::Shipment] a working artifact, packaged from a dirty tree
  def store_shipment(build_name, dirty: true)
    dir = @root / "store" / build_name
    dir.mkpath
    (dir / "#{build_name}.tar").write("image bytes")
    metadata = dirty ? "#{RELEASE_SHA[0, 12]}.dirty.20261106T120000Z" : RELEASE_SHA[0, 12]
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: RELEASE_NOON),
      build: build(build_name),
      state: Dev::Lifecycle::GitState.new(sha: RELEASE_SHA[0, 12], dirty:),
      packaged_at: RELEASE_NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+#{metadata}"),
      archive: "#{build_name}.tar",
      archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir:, manifest:))
  end

  def channel
    Dev::Lifecycle::Channel.new(
      name: "ghcr", desc: "GHCR", accepts: [Dev::Lifecycle::BuildPattern.parse("rspock", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "ghcr"),
    )
  end

  test "on the live track each archive is loaded, tagged with the release version and pushed, inside one write-scoped GHCR session" do
    Given "two image tarballs, each loaded under the builder's own tag"
    rspock = release_shipment("rspock")
    server = release_shipment("cellbound-3d-server-linux64-release")
    engine = engine_loading({
      "rspock-ue5.8-3.tar" => "Loaded image: #{IMAGE}:ue5.8\nLoaded image: #{IMAGE}:local\n",
      "cellbound-3d-server-linux64-release-ue5.8-3.tar" => "Loaded image: ghcr.io/d3mlabs/unreal-engine:local\n",
    })
    publisher = Dev::Deps::GhcrPublisher.new(engine:, login: @login)

    When
    receipt = publisher.publish([rspock, server], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".ghcr")

    Then "both loads before the session; tag then push per image, in order; the receipt is what landed"
    receipt == Dev::Lifecycle::Receipt.new(summary: "pushed #{IMAGE}:ue5.8-3, ghcr.io/d3mlabs/unreal-engine:ue5.8-3")
    engine.captures == [["load", "--input", rspock.archive.to_s], ["load", "--input", server.archive.to_s]]
    engine.runs == [
      ["tag", "#{IMAGE}:ue5.8", "#{IMAGE}:ue5.8-3"],
      ["push", "#{IMAGE}:ue5.8-3"],
      ["tag", "ghcr.io/d3mlabs/unreal-engine:local", "ghcr.io/d3mlabs/unreal-engine:ue5.8-3"],
      ["push", "ghcr.io/d3mlabs/unreal-engine:ue5.8-3"],
    ]
    @login.sessions == [["ghcr.io", true]]
    !(@root / ".ghcr").exist?
  end

  test "on the testing track a working artifact is pushed under its build id, spelled as a docker tag behind the testing prefix: #{dirty ? "dirty" : "clean"}" do
    Given
    shipment = store_shipment("rspock", dirty:)
    engine = engine_loading({ "rspock.tar" => "Loaded image: #{IMAGE}:local\n" })

    When
    receipt = Dev::Deps::GhcrPublisher.new(engine:, login: @login).publish([shipment], channel:, track: Dev::Lifecycle::Track::Testing, scratch: @root / ".ghcr")

    Then
    receipt == Dev::Lifecycle::Receipt.new(summary: "pushed #{IMAGE}:#{tag}")
    engine.runs == [["tag", "#{IMAGE}:local", "#{IMAGE}:#{tag}"], ["push", "#{IMAGE}:#{tag}"]]
    @login.sessions == [["ghcr.io", true]]

    Where
    dirty | tag
    true  | "testing-1.2.0-3f2a1c9d8e7b.dirty.20261106T120000Z"
    false | "testing-1.2.0-3f2a1c9d8e7b"
  end

  test "an archive the engine cannot load, or loads badly, refuses the whole deploy before any push: #{what}" do
    Given "a good archive after the bad one"
    bad = release_shipment("rspock")
    good = release_shipment("cellbound-3d-server-linux64-release")
    engine = engine_loading({ "rspock-ue5.8-3.tar" => output, "cellbound-3d-server-linux64-release-ue5.8-3.tar" => "Loaded image: #{IMAGE}:local\n" })

    When
    Dev::Deps::GhcrPublisher.new(engine:, login: @login).publish([bad, good], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".ghcr")

    Then "the error names the archive; no session was opened and nothing ran"
    error = raises(error_class)
    error.message.include?("rspock-ue5.8-3.tar")
    error.message.include?(names)
    engine.runs.empty?
    @login.sessions.empty?

    Where
    what                        | output                                                                   | error_class                                   | names
    "not a tarball"             | ""                                                                       | Dev::Deps::GhcrPublisher::LoadFailedError     | "docker save"
    "an untagged image"         | "Loaded image ID: sha256:0123abcd\n"                                     | Dev::Deps::GhcrPublisher::UntaggedImageError  | "no repository tag"
    "a Docker Hub image"        | "Loaded image: ubuntu:24.04\n"                                           | Dev::Deps::GhcrPublisher::ForeignRegistryError | "ubuntu:24.04"
    "another registry's image"  | "Loaded image: docker.io/d3mlabs/x:1\n"                                  | Dev::Deps::GhcrPublisher::ForeignRegistryError | "docker.io/d3mlabs/x:1"
    "two repositories"          | "Loaded image: #{IMAGE}:a\nLoaded image: ghcr.io/d3mlabs/other:b\n"      | Dev::Deps::GhcrPublisher::AmbiguousImageError | "ghcr.io/d3mlabs/other"
  end

  test "a release version that is not a docker tag is refused before any push" do
    Given
    shipment = release_shipment("rspock", version: "1.2.0+build")
    engine = engine_loading({ "rspock-1.2.0+build.tar" => "Loaded image: #{IMAGE}:local\n" })

    When
    Dev::Deps::GhcrPublisher.new(engine:, login: @login).publish([shipment], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".ghcr")

    Then
    error = raises(Dev::Deps::GhcrPublisher::InvalidTagError)
    error.message.include?("1.2.0+build")
    engine.runs.empty?
  end

  test "the live track over a store artifact is a wiring bug, named as such" do
    Given
    engine = engine_loading({ "rspock.tar" => "Loaded image: #{IMAGE}:local\n" })

    When
    Dev::Deps::GhcrPublisher.new(engine:, login: @login).publish([store_shipment("rspock")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".ghcr")

    Then
    raises Dev::Deps::GhcrPublisher::LiveTrackWithoutReleaseError
    engine.runs.empty?
  end

  test "a docker #{step} the engine refuses ends the deploy there, inside the session" do
    Given
    shipment = release_shipment("rspock")
    engine = engine_loading({ "rspock-ue5.8-3.tar" => "Loaded image: #{IMAGE}:local\n" }, refuse: [step, *refused])

    When
    Dev::Deps::GhcrPublisher.new(engine:, login: @login).publish([shipment], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".ghcr")

    Then
    error = raises(error_class)
    error.message.include?("#{IMAGE}:ue5.8-3")
    engine.runs.size == runs
    @login.sessions == [["ghcr.io", true]]

    Where
    step   | refused                                | error_class                               | runs
    "tag"  | ["#{IMAGE}:local", "#{IMAGE}:ue5.8-3"] | Dev::Deps::GhcrPublisher::TagFailedError  | 1
    "push" | ["#{IMAGE}:ue5.8-3"]                   | Dev::Deps::GhcrPublisher::PushFailedError | 2
  end

  test "the engine and the login are resolved on first use: the publisher the Registry builds at load reads no engine record" do
    Given "no engine and no login handed in"
    publisher = Dev::Deps::GhcrPublisher.new

    Expect "construction completes with neither resolved, and the tool name renders"
    publisher.instance_variable_get(:@engine).nil?
    publisher.instance_variable_get(:@login).nil?
    publisher.to_s == "docker push"
  end
end
