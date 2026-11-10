# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a packager wrote for one build: the **archive** — the file
    # `build-id.json` names, a release attaches first and a channel reads
    # first — and, for the split tar form, the parts the archive's
    # `MANIFEST` lists (dev#192, K1). One file for a zip, a `.tar.zst`, a
    # `.gem` or an adopted install; `<build>.MANIFEST` plus
    # `<build>.tar.zst.00…` for a split set. Every path is in the artifact
    # directory, beside the manifest the stage stamps afterwards.
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
