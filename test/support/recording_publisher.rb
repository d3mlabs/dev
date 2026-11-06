# typed: false
# frozen_string_literal: true

require "dev/lifecycle"
require "pathname"

# A Publisher that remembers what it was asked to ship — the port an
# integration contributes through the Registry's `publisher:` (dev#422),
# minus the protocol. Each instance records only its own calls, so tests
# share no state through it; the `project_root:` constructor kwarg is the
# shape Registry.publishers slices from its context.
class RecordingPublisher
  include Dev::Lifecycle::Publisher

  Shipment = Data.define(:artifacts, :channel, :track, :scratch)

  attr_reader :project_root, :shipments

  # @param project_root [Pathname, nil] what the Registry hands a publisher that asks for it
  def initialize(project_root: nil)
    @project_root = project_root
    @shipments = []
  end

  # @param artifacts [Array<Dev::Lifecycle::Artifact>]
  # @param channel [Dev::Lifecycle::Channel]
  # @param track [Dev::Lifecycle::Track]
  # @param scratch [Pathname]
  # @return [void]
  def publish(artifacts, channel:, track:, scratch:)
    @shipments << Shipment.new(artifacts:, channel:, track:, scratch:)
  end

  # @return [String]
  def to_s = "recording"
end
