# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "build_dispatcher"
require_relative "command"

module Dev
  module Cli
    # What `dev help build` and `dev help package` list, and what Tab
    # completion offers after them: every build the
    # project's targets derive, in declaration order — the first is the bare
    # verb's default — each with the placement its target declares for it,
    # and a note when this machine cannot produce it there (a host build of
    # another platform). The placement comes from the same dispatcher the
    # verbs run through, so the column and the run agree.
    #
    # The targets and the dispatcher are fixed for a run and
    # constructor-owned.
    class BuildListing
      extend T::Sig

      HEADING = "Builds"

      # @param targets [Array<Lifecycle::Target>] in declaration order
      # @param dispatcher [BuildDispatcher]
      sig { params(targets: T::Array[Lifecycle::Target], dispatcher: BuildDispatcher).void }
      def initialize(targets:, dispatcher:)
        @targets = targets
        @dispatcher = dispatcher
      end

      # The section for a verb's usage.
      #
      # @param targets [Array<Lifecycle::Target>] the targets the verb acts
      #   on — every one for `build`, the packageable ones for `package`
      # @return [LifecycleCommand::Listing]
      sig { params(targets: T::Array[Lifecycle::Target]).returns(LifecycleCommand::Listing) }
      def listing(targets: @targets)
        listing_of(targets.flat_map(&:builds))
      end

      # The section for a verb acting on a fixed set of builds rather than
      # on whole targets — the release's builds (`dev help release`).
      #
      # @param builds [Array<Lifecycle::Build>] in the order the verb acts on them
      # @param heading [String]
      # @return [LifecycleCommand::Listing]
      sig { params(builds: T::Array[Lifecycle::Build], heading: String).returns(LifecycleCommand::Listing) }
      def listing_of(builds, heading: HEADING)
        LifecycleCommand::Listing.new(heading:, subjects: builds.map { |build| subject(build) })
      end

      # Every name a verb's positional admits: each target's patterns and
      # fully-qualified builds (Target#pattern_names), in declaration order.
      #
      # @param targets [Array<Lifecycle::Target>] as for #listing
      # @return [Array<String>]
      sig { params(targets: T::Array[Lifecycle::Target]).returns(T::Array[String]) }
      def completions(targets: @targets)
        targets.flat_map(&:pattern_names)
      end

      private

      # One build's row: its name, its target's description, its placement —
      # left unbound (no column) when the lock could not place it at load, as
      # a command's row is — and the host note when this machine is not the
      # build's platform.
      #
      # @param build [Lifecycle::Build]
      # @return [LifecycleCommand::Subject]
      sig { params(build: Lifecycle::Build).returns(LifecycleCommand::Subject) }
      def subject(build)
        return LifecycleCommand::Subject.new(name: build.name, desc: build.target.desc) unless @dispatcher.bound?(build)

        placement = @dispatcher.placement_for(build)
        note = @dispatcher.buildable_here?(build) ? nil : "(#{build.platform} only)"
        LifecycleCommand::Subject.new(name: build.name, desc: build.target.desc, placement:, note:)
      end
    end
  end
end
