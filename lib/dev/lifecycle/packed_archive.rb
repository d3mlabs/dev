# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a packager wrote for one build: the archive file `build-id.json`
    # names and, for a split tar, the parts its `MANIFEST` lists. Every path
    # is in the artifact directory.
    class PackedArchive < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [Pathname] the file that stands for the archive
      const :archive, Pathname
      # @return [Array<Pathname>] the archive's parts, in order; empty when
      #   the archive is one file
      const :parts, T::Array[Pathname], default: []

      # @return [Array<Pathname>] every file written, the archive first
      sig { returns(T::Array[Pathname]) }
      def files
        [archive, *parts]
      end

      # @return [String] the archive's file name, what the manifest records
      sig { returns(String) }
      def name
        archive.basename.to_s
      end

      # @return [Boolean] whether the archive is a split set
      sig { returns(T::Boolean) }
      def split?
        !parts.empty?
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [archive, parts]
      end
    end
  end
end
