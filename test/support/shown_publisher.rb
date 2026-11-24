# typed: false
# frozen_string_literal: true

require "dev/lifecycle"
require "pathname"
require "support/recording_publisher"

# A Publisher that remembers the trees it was shown at package
# (Publisher#accept!) and refuses them when told to. The tree a packager
# presents is a scratch gone once the archive is written, so what the
# tree held is recorded at the moment it was shown.
class ShownPublisher < RecordingPublisher
  # The refusal, worded by the channel.
  class RefusedError < RuntimeError; end

  # One `accept!` call: the tree, its top-level entries then, the channel.
  Shown = Data.define(:tree, :entries, :channel)

  attr_reader :shown

  # @param refuse [Boolean] whether every tree is refused
  def initialize(refuse: false)
    super()
    @refuse = refuse
    @shown = []
  end

  # @param tree [Pathname]
  # @param channel [Dev::Lifecycle::Channel]
  # @raise [RefusedError] when refusing
  def accept!(tree, channel:)
    entries = tree.directory? ? tree.children.map { |child| child.basename.to_s }.sort : []
    @shown << Shown.new(tree:, entries:, channel:)
    raise RefusedError, "#{channel} refuses the tree" if @refuse
  end
end
