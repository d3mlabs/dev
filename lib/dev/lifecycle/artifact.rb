# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build"
require_relative "git_state"
require_relative "manifest"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # One artifact in the store: the directory `package` filled for a build —
    # the archive (the one file a release attaches and a channel uploads) and
    # the `build-id.json` that says what it was packaged from (dev#192, K0,
    # K9). The manifest is the truth about the directory; the directory's
    # name is only the index the Store reaches it by.
    class Artifact
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [Pathname] the artifact's directory in the store
      sig { returns(Pathname) }
      attr_reader :dir

      sig { returns(Manifest::Artifact) }
      attr_reader :manifest

      # @param dir [Pathname]
      # @param manifest [Manifest::Artifact]
      sig { params(dir: Pathname, manifest: Manifest::Artifact).void }
      def initialize(dir:, manifest:)
        @dir = dir
        @manifest = manifest
        freeze
      end

      # @return [Build]
      sig { returns(Build) }
      def build
        @manifest.build
      end

      # @return [String] the build's fully-qualified name
      sig { returns(String) }
      def name
        @manifest.build.name
      end

      # @return [Pathname] the archive, beside the manifest
      sig { returns(Pathname) }
      def archive
        @dir / @manifest.archive
      end

      # Whether the artifact is up to date with a working tree
      # (Manifest::Artifact#current?).
      #
      # @param state [GitState]
      # @return [Boolean]
      sig { params(state: GitState).returns(T::Boolean) }
      def current?(state)
        @manifest.current?(state)
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@dir, @manifest]
      end
    end
  end
end
