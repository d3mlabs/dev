# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "support/recording_publisher"
require "support/shown_publisher"
require "pathname"

# The destinations' say over a tree before it is archived: each channel's
# publisher is shown the tree in order; the first refusal is the
# publisher's own, and nothing after it is asked.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::AcceptanceTest < Minitest::Test
  include LifecycleFixtures

  def channel(name)
    Dev::Lifecycle::Channel.new(
      name:, accepts: [Dev::Lifecycle::BuildPattern.new(target: gem_target)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name:),
    )
  end

  test "the unconditional acceptance has no one to ask and accepts any tree" do
    Given
    acceptance = Dev::Lifecycle::Acceptance.unconditional

    When
    acceptance.accept!(Pathname("/anywhere"))

    Then "nothing raised for a tree that does not exist: no one looked"
    acceptance.unconditional?
    acceptance.acceptors == {}
  end

  test "every acceptor is shown the tree with its own channel, in order" do
    Given
    gh = ShownPublisher.new
    brew = ShownPublisher.new
    acceptance = Dev::Lifecycle::Acceptance.new(acceptors: { channel("gh") => gh, channel("brew") => brew })

    When
    acceptance.accept!(Pathname("/stage"))

    Then
    !acceptance.unconditional?
    gh.shown.map { |shown| [shown.tree, shown.channel] } == [[Pathname("/stage"), channel("gh")]]
    brew.shown.map { |shown| [shown.tree, shown.channel] } == [[Pathname("/stage"), channel("brew")]]
  end

  test "the first refusal is raised as the publisher words it, and the channels after it are not asked" do
    Given
    refusing = ShownPublisher.new(refuse: true)
    after = ShownPublisher.new
    acceptance = Dev::Lifecycle::Acceptance.new(acceptors: { channel("gh") => refusing, channel("brew") => after })

    When
    acceptance.accept!(Pathname("/stage"))

    Then
    error = raises(ShownPublisher::RefusedError)
    error.message == "gh refuses the tree"
    after.shown.empty?
  end

  test "a publisher that says nothing of trees accepts every one: the port's default" do
    Given
    publisher = RecordingPublisher.new
    acceptance = Dev::Lifecycle::Acceptance.new(acceptors: { channel("steam") => publisher })

    When
    acceptance.accept!(Pathname("/stage"))

    Then "nothing raised, and nothing shipped either: accepting is not publishing"
    publisher.calls.empty?
  end
end
