# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle/build_pattern"
require "dev/lifecycle/channel"
require "dev/lifecycle/publisher_spec"
require "dev/lifecycle/series"
require "dev/lifecycle/target"
require "dev/stream"

transform!(RSpock::AST::Transformation)
class Dev::StreamTest < Minitest::Test
  AI_FLOW_V1 = Dev::Stream.new(repo: "d3mlabs/ai-flow", series: Dev::Lifecycle::Series.new(1))

  test "a stream is spelled as the constraint a host declares — the repo, the gh channel, the pessimistic major" do
    Expect
    AI_FLOW_V1.to_s == "d3mlabs/ai-flow@gh ~> 1"
    AI_FLOW_V1.head_tag == "v1"
    AI_FLOW_V1.name == "ai-flow"
    AI_FLOW_V1.frozen?
  end

  test "parse reads the spelling back, whitespace around it ignored: #{word.inspect}" do
    Expect
    Dev::Stream.parse(word) == AI_FLOW_V1

    Where
    word
    "d3mlabs/ai-flow@gh ~> 1"
    "  d3mlabs/ai-flow@gh ~> 1\n"
  end

  test "a word that is not a stream is refused: #{word.inspect}" do
    When
    Dev::Stream.parse(word)

    Then
    error = raises Dev::Stream::MalformedError
    error.message.include?(word.inspect)

    Where
    word
    "ai-flow@gh ~> 1"
    "d3mlabs/ai-flow@brew ~> 1"
    "d3mlabs/ai-flow@gh ~> 1.2"
    "d3mlabs/ai-flow@gh >= 1"
    "d3mlabs/ai-flow@gh ~> v1"
    "d3mlabs/ai-flow"
    ""
  end

  test "a release tag is of the stream when it names a release of the series: #{tag} → #{included}" do
    Expect
    AI_FLOW_V1.includes_tag?(tag) == included

    Where
    tag              | included
    "v1.0.0"         | true
    "v1.12.3"        | true
    "v2.0.0"         | false
    "v0.9.0"         | false
    "v1"             | false
    "v1.0.0-rc.1"    | false
    "1.0.0"          | false
    "toolchain-1"    | false
  end

  test "a project is deployed through gh when a channel's publisher is the gh integration — a run: child named gh is not it" do
    Expect
    Dev::Stream.deployed_through_gh?("gh" => channel("gh", Dev::Lifecycle::PublisherSpec::Integration.new(name: "gh")))
    Dev::Stream.deployed_through_gh?("release" => channel("release", Dev::Lifecycle::PublisherSpec::Integration.new(name: "gh")))
    !Dev::Stream.deployed_through_gh?("brew" => channel("brew", Dev::Lifecycle::PublisherSpec::Integration.new(name: "brew")))
    !Dev::Stream.deployed_through_gh?("gh" => channel("gh", Dev::Lifecycle::PublisherSpec::Script.new(command: "./bin/publish-gh")))
    !Dev::Stream.deployed_through_gh?({})
  end

  test "a head's tag is the release tag its version names — the version word its tree is installed under" do
    Expect
    Dev::Stream::Head.new(version: "1.4.2", commit: "abc").tag == "v1.4.2"
  end

  test "two streams are the same stream exactly when repo and series are" do
    Expect
    assert_value_semantics AI_FLOW_V1,
      equal_to: Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 1"),
      unequal_to: [
        Dev::Stream.new(repo: "d3mlabs/ai-flow", series: Dev::Lifecycle::Series.new(2)),
        Dev::Stream.new(repo: "d3mlabs/dev", series: Dev::Lifecycle::Series.new(1)),
      ]
  end

  private

  def channel(name, publisher)
    Dev::Lifecycle::Channel.new(
      name: name,
      accepts: [Dev::Lifecycle::BuildPattern.new(target: Dev::Lifecycle::Target.new(name: "ai-flow"))],
      publisher: publisher,
    )
  end
end
