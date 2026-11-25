# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "build"
require_relative "builder"
require_relative "git"

module Dev
  module Lifecycle
    # The identity builder: what a target with no `builder:` gets. Its stage
    # is the checkout itself — the tracked files, as the working tree holds
    # them, copied into the stage with their modes and symlinks kept. Only
    # tracked files: what is ignored or untracked (`coverage/`, `vendor/`,
    # a nested checkout) never reaches the stage, so a target whose
    # shippable tree is a selection of the repo needs no script to say so.
    # Which of those files ship is the packager's question, not this one's.
    #
    # This is to build what `as-is` is to package: the stage's identity
    # element. `build-id.json` records it as `checkout`.
    #
    # The project root is fixed for a checkout and so is constructor-owned;
    # the build is per call.
    class CheckoutBuilder
      extend T::Sig
      include Builder

      # The project root is not inside a git working tree, so there are no
      # tracked files to stage.
      class NotACheckoutError < RuntimeError; end

      # What the manifest records for a stage the checkout is.
      NAME = "checkout"

      # @param project_root [Pathname] the checkout whose tracked files are the stage
      sig { params(project_root: Pathname).void }
      def initialize(project_root:)
        @project_root = project_root
        @git = T.let(Git.new(root: project_root), Git)
      end

      # @param build [Build] unused: the checkout is the same for every build of the target
      # @param stage [Pathname] the fresh stage
      # @return [void]
      # @raise [NotACheckoutError]
      # @raise [Git::CommandFailedError]
      # @raise [Git::GitMissingError]
      sig { override.params(build: Build, stage: Pathname).void }
      def fill(build, stage)
        _ = build
        tracked_files.each do |relative|
          source = @project_root / relative
          # An index entry whose file was deleted from the working tree is
          # not in the checkout; a gitlink (a submodule's or a nested
          # checkout's root) is another repository's tree, not a file here.
          next unless source.symlink? || source.exist?
          next if source.directory? && !source.symlink?

          destination = stage / relative
          destination.dirname.mkpath
          FileUtils.copy_entry(source, destination, true)
        end
      end

      # The checkout takes no target options.
      sig { override.returns(T::Array[String]) }
      def target_options_schema
        []
      end

      sig { override.returns(String) }
      def name
        NAME
      end

      # The checkout has no version of its own: the tree it is is the
      # provenance, and the manifest's sha records that.
      sig { override.returns(T.nilable(String)) }
      def version
        nil
      end

      # What `dev help` renders for a target with no `builder:`.
      sig { returns(String) }
      def to_s
        NAME
      end

      private

      # The paths git tracks under the project root, relative to it.
      #
      # @return [Array<Pathname>]
      # @raise [NotACheckoutError]
      # @raise [Git::CommandFailedError]
      # @raise [Git::GitMissingError]
      sig { returns(T::Array[Pathname]) }
      def tracked_files
        unless @git.succeeds?(["rev-parse", "--is-inside-work-tree"])
          raise NotACheckoutError,
            "#{@project_root} is not a git checkout, so a target with no `builder:` has no tracked files to stage"
        end

        @git.capture(["ls-files", "-z"]).split("\0").map { |path| Pathname(path) }
      end
    end
  end
end
