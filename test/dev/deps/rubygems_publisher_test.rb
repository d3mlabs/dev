# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/rubygems_publisher"
require "dev/lifecycle"
require "support/release_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RubygemsPublisherTest < Minitest::Test
  include ReleaseFixtures

  # A shell that remembers each run and answers with what a real child did
  # — `true`, or `false` for the archives it is told to refuse.
  class RecordingShell < Dev::Lifecycle::Shell
    Run = Data.define(:argv, :chdir, :env)

    attr_reader :runs

    def initialize(refuse: [])
      super()
      @refuse = refuse
      @runs = []
    end

    def run(argv, chdir:, env: {})
      @runs << Run.new(argv:, chdir:, env:)
      _pid, status = Process.wait2(Process.spawn(@refuse.any? { |name| argv.last.end_with?(name) } ? "false" : "true"))
      status
    end
  end

  # A credential provider that remembers what it was asked for.
  class RecordingCredentials
    attr_reader :asks

    def initialize
      @asks = []
    end

    def resolve(**ask)
      @asks << ask
      "rubygems_key"
    end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("rubygems-publisher-"))
    @project = @root / "project"
    @project.mkpath
    @shell = RecordingShell.new
    @credentials = RecordingCredentials.new
    @publisher = Dev::Deps::RubygemsPublisher.new(project_root: @project, shell: @shell, credentials: @credentials)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # @return [Dev::Lifecycle::Shipment] a release's archive of the gem target
  def release_shipment(build_name, version: "1.2.0", extension: "gem")
    archive = @root / "releases" / "#{build_name}-#{version}.#{extension}"
    archive.dirname.mkpath
    archive.write("gem bytes of #{build_name}")
    entry = release_entry(build_name, bytes: archive.read, version:, extension:)
    Dev::Lifecycle::Shipment.of_release(entry, archive:, tag: Dev::Lifecycle::ReleaseTag.new(version), sha: RELEASE_SHA)
  end

  # @return [Dev::Lifecycle::Shipment] a working artifact of the gem target
  def store_shipment(build_name)
    dir = @root / "store" / build_name
    dir.mkpath
    (dir / "#{build_name}.gem").write("gem bytes")
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: RELEASE_NOON),
      build: build(build_name),
      state: Dev::Lifecycle::GitState.new(sha: RELEASE_SHA[0, 12], dirty: true),
      packaged_at: RELEASE_NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+#{RELEASE_SHA[0, 12]}.dirty.20261106T120000Z"),
      archive: "#{build_name}.gem",
      archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir:, manifest:))
  end

  def channel
    Dev::Lifecycle::Channel.new(
      name: "rubygems", desc: "rubygems.org", accepts: [Dev::Lifecycle::BuildPattern.parse("rspock", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "rubygems"),
    )
  end

  test "on the live track every gem is pushed in order, at the project root, to rubygems.org, with the key in the env and never on argv" do
    Given "two release archives"
    rspock = release_shipment("rspock")
    server = release_shipment("cellbound-3d-server-linux64-release")

    When
    receipt = @publisher.publish([rspock, server], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".rubygems")

    Then "one `gem push --host` per archive, the key resolved once through the provider"
    receipt == Dev::Lifecycle::Receipt.new(summary: "pushed to https://rubygems.org: rspock-1.2.0.gem, cellbound-3d-server-linux64-release-1.2.0.gem")
    @shell.runs.map(&:argv) == [
      ["gem", "push", "--host", "https://rubygems.org", rspock.archive.to_s],
      ["gem", "push", "--host", "https://rubygems.org", server.archive.to_s],
    ]
    @shell.runs.map(&:chdir).uniq == [@project]
    @shell.runs.map(&:env).uniq == [{ "GEM_HOST_API_KEY" => "rubygems_key" }]
    @shell.runs.flat_map(&:argv).none? { |arg| arg.include?("rubygems_key") }
    @credentials.asks == [{
      namespace: "rubygems", key: "api_key", env_var: "GEM_HOST_API_KEY",
      prompt_label: "rubygems.org API key with push scope", create_url: "https://rubygems.org/profile/api_keys/new",
    }]
    !(@root / ".rubygems").exist?
  end

  test "the testing track is refused before anything runs: rubygems.org has no track that is not live" do
    Given
    shipment = store_shipment("rspock")

    When
    @publisher.publish([shipment], channel:, track: Dev::Lifecycle::Track::Testing, scratch: @root / ".rubygems")

    Then "the refusal names the release path, and neither the key nor gem was touched"
    error = raises(Dev::Deps::RubygemsPublisher::TestingTrackUnsupportedError)
    error.message.include?("dev deploy rubygems --release <version>")
    @shell.runs.empty?
    @credentials.asks.empty?
  end

  test "an archive that is not a .gem refuses the whole set before the first push" do
    Given "a gem, then a zip"
    gem = release_shipment("rspock")
    zip = release_shipment("cellbound-3d-win64-release", extension: "zip")

    When
    @publisher.publish([gem, zip], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".rubygems")

    Then "the zip is named with the fix, and the gem before it did not go live"
    error = raises(Dev::Deps::RubygemsPublisher::NotAGemError)
    error.message.include?("cellbound-3d-win64-release-1.2.0.zip")
    error.message.include?("packager")
    @shell.runs.empty?
  end

  test "a push rubygems.org refuses ends the deploy at that gem, naming it and the exit" do
    Given "the first of two pushes fails"
    shell = RecordingShell.new(refuse: ["rspock-1.2.0.gem"])
    publisher = Dev::Deps::RubygemsPublisher.new(project_root: @project, shell:, credentials: @credentials)
    rspock = release_shipment("rspock")
    server = release_shipment("cellbound-3d-server-linux64-release")

    When
    publisher.publish([rspock, server], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".rubygems")

    Then "the error names the gem and the exit; the second gem was not pushed"
    error = raises(Dev::Deps::RubygemsPublisher::PushFailedError)
    error.message.include?("gem push rspock-1.2.0.gem")
    error.message.include?("exited 1")
    shell.runs.size == 1
  end

  test "a missing gem executable surfaces as the shell's spawn error" do
    Given "a publisher over the real shell, in a project root that does not exist"
    publisher = Dev::Deps::RubygemsPublisher.new(project_root: @root / "missing", credentials: @credentials)

    When
    publisher.publish([release_shipment("rspock")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @root / ".rubygems")

    Then
    raises Dev::Lifecycle::Shell::SpawnError
  end

  test "the publisher renders as the tool it runs" do
    Expect
    @publisher.to_s == "gem push"
  end
end
