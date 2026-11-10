# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_ref"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ChannelTest < Minitest::Test
  include LifecycleFixtures

  def pattern(name)
    Dev::Lifecycle::BuildPattern.parse(name, all_targets)
  end

  def script(command = "./bin/stage", environment: nil)
    Dev::Lifecycle::PublisherSpec::Script.new(command:, environment:)
  end

  def staging
    Dev::Lifecycle::Channel.new(name: "staging", desc: "rsync to the gamebox", accepts: [pattern("cellbound-3d-win64")], publisher: script)
  end

  test "a channel accepts the builds its patterns span, each once, in accept order" do
    Given "a store channel over two depots, one pattern admitting a build the other does too"
    steam = Dev::Lifecycle::Channel.new(
      name: "steam", accepts: [pattern("cellbound-3d-steamworks"), pattern("cellbound-3d-server"), pattern("cellbound-3d-server-release")],
      publisher: script,
    )

    Expect
    steam.builds.map(&:name) == ["cellbound-3d-steamworks-win64-release", "cellbound-3d-server-linux64-dev", "cellbound-3d-server-linux64-release"]
    steam.accepts?(build("cellbound-3d-server-linux64-dev"))
    !steam.accepts?(build("cellbound-3d-win64-dev"))
    steam.desc == "(no description)"
    steam.to_s == "steam"
  end

  test "the artifact patterns spell every platform out and leave the config as declared: one artifact ships per entry" do
    Given "a channel accepting the client on any platform and config, the steamworks build fully, and the gem"
    channel = Dev::Lifecycle::Channel.new(
      name: "mirror", accepts: [pattern("cellbound-3d"), pattern("cellbound-3d-steamworks-win64-release"), pattern("rspock")], publisher: script,
    )

    Expect "two client entries (one per platform, config open), the steamworks one as written, the gem as its own"
    channel.artifact_patterns.map(&:name) == ["cellbound-3d-win64", "cellbound-3d-linux64", "cellbound-3d-steamworks-win64-release", "rspock"]
    channel.artifact_patterns.first.config.nil?
  end

  test "a channel accepting nothing is refused by name" do
    When
    Dev::Lifecycle::Channel.new(name: "void", accepts: [], publisher: script)

    Then
    e = raises Dev::Lifecycle::Channel::EmptyAcceptSetError
    e.message == "channel 'void': `targets:` lists no build — name the builds it accepts"
  end

  test "channels and script publisher declarations compare by value; the declaration renders as its run: line" do
    Given
    host = Dev::EnvironmentRef::Host.new

    Expect
    staging == staging
    staging.eql?(staging)
    staging.hash == staging.hash
    staging != Dev::Lifecycle::Channel.new(name: "staging", desc: "rsync to the gamebox", accepts: [pattern("cellbound-3d-win64")], publisher: script("./bin/other"))
    script("./bin/stage", environment: host) == script("./bin/stage", environment: host)
    script("./bin/stage", environment: host) != script("./bin/stage")
    script("./bin/stage", environment: host).hash == script("./bin/stage", environment: host).hash
    script.to_s == "run: ./bin/stage"
    script.environment.nil?
  end

  test "a channel carries its publisher's options verbatim, empty unless declared, and they take part in equality (dev#426)" do
    Given
    integration = Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam")
    plain = Dev::Lifecycle::Channel.new(name: "steam", accepts: [pattern("cellbound-3d-win64")], publisher: integration)
    configured = Dev::Lifecycle::Channel.new(name: "steam", accepts: [pattern("cellbound-3d-win64")], publisher: integration, options: { "app" => 480 })

    Expect
    plain.options == {}
    configured.options == { "app" => 480 }
    configured == Dev::Lifecycle::Channel.new(name: "steam", accepts: [pattern("cellbound-3d-win64")], publisher: integration, options: { "app" => 480 })
    configured.hash == Dev::Lifecycle::Channel.new(name: "steam", accepts: [pattern("cellbound-3d-win64")], publisher: integration, options: { "app" => 480 }).hash
    plain != configured
  end
end
