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

  # One `publish` call as it was made.
  Call = Data.define(:shipments, :channel, :track, :scratch)

  attr_reader :project_root, :calls

  # @param project_root [Pathname, nil] what the Registry hands a publisher that asks for it
  def initialize(project_root: nil)
    @project_root = project_root
    @calls = []
  end

  # @param shipments [Array<Dev::Lifecycle::Shipment>]
  # @param channel [Dev::Lifecycle::Channel]
  # @param track [Dev::Lifecycle::Track]
  # @param scratch [Pathname]
  # @return [Dev::Lifecycle::Receipt] names the builds shipped, as an integration's would
  def publish(shipments, channel:, track:, scratch:)
    @calls << Call.new(shipments:, channel:, track:, scratch:)
    Dev::Lifecycle::Receipt.new(summary: "recorded #{shipments.map(&:name).join(", ")}")
  end

  # @return [String]
  def to_s = "recording"
end
