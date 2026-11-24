# typed: strict
# frozen_string_literal: true

require "pathname"
# Channel and Publisher appear in signatures only, which are resolved
# lazily; requiring channel.rb here would close a load cycle (Channel →
# Build → Target → PackagerSpec → Archive → Packager → this). `dev/lifecycle`
# loads all of them.

module Dev
  module Lifecycle
    # The destinations' say over a tree before it becomes an archive: the
    # publisher of every channel whose accept set holds the build, each
    # asked in turn (Publisher#accept!) with the tree the packager is about
    # to write — after it selected, before anything is written — so a tree
    # a destination would refuse never becomes an asset. Which channels
    # those are is the verb's to decide; the packager only presents the
    # tree. The first refusal is the packager's failure.
    #
    # The empty set is the identity — nothing to ask, every tree accepted:
    # what `dev pack` runs with, and a project with no channels.
    class Acceptance
      extend T::Sig

      Acceptors = T.type_alias { T::Hash[Channel, Publisher] }

      class << self
        extend T::Sig

        # The identity: no destination to ask.
        #
        # @return [Acceptance]
        sig { returns(Acceptance) }
        def unconditional
          new(acceptors: {})
        end
      end

      # @return [Hash{Channel => Publisher}] the channels asked, with their publishers, in accept order
      sig { returns(Acceptors) }
      attr_reader :acceptors

      # @param acceptors [Hash{Channel => Publisher}] the channels whose
      #   accept set holds the build, each with its publisher
      sig { params(acceptors: Acceptors).void }
      def initialize(acceptors:)
        @acceptors = acceptors
      end

      # Whether there is anyone to ask.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def unconditional?
        @acceptors.empty?
      end

      # Present the tree to every destination, in order; the first refusal
      # is raised as the publisher words it.
      #
      # @param tree [Pathname] the tree about to be archived
      # @return [void]
      # @raise [StandardError] the refusing publisher's own error
      sig { params(tree: Pathname).void }
      def accept!(tree)
        @acceptors.each { |channel, publisher| publisher.accept!(tree, channel:) }
      end
    end
  end
end
