# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The `MANIFEST` of a split archive: one `<sha256>  <part file name>`
    # line per part, in part order, the shape `sha256sum -c` reads. Written
    # by Archive, renamed by ReleaseAssets, read by ReleaseArchives.
    class PartList < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

      # A line that is not `<sha256>  <part>`.
      class MalformedPartListError < RuntimeError; end

      # One part: its digest and its file name, as listed.
      class Part < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :sha256, String
        const :name, String
        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [sha256, name]
        end
      end

      const :parts, T::Array[Part]

      class << self
        extend T::Sig

        # The list of the parts in a directory, each hashed.
        #
        # @param files [Array<Pathname>] the parts, in order
        # @return [PartList]
        sig { params(files: T::Array[Pathname]).returns(PartList) }
        def of(files)
          new(parts: files.map { |file| Part.new(sha256: Digest::SHA256.file(file.to_s).hexdigest, name: file.basename.to_s) })
        end

        # Read a MANIFEST file.
        #
        # @param path [Pathname]
        # @return [PartList]
        # @raise [MalformedPartListError]
        sig { params(path: Pathname).returns(PartList) }
        def read(path)
          parts = path.read.lines.map do |line|
            sha, name = line.strip.split(/\s+/, 2)
            raise MalformedPartListError, "#{path}: '#{line.strip}' is not `<sha256>  <part>`" if sha.nil? || name.nil?

            Part.new(sha256: sha, name:)
          end
          new(parts:)
        end
      end

      # The file's content.
      #
      # @return [String]
      sig { returns(String) }
      def render
        parts.map { |part| "#{part.sha256}  #{part.name}\n" }.join
      end

      # Write the list as a MANIFEST file.
      #
      # @param path [Pathname]
      # @return [void]
      sig { params(path: Pathname).void }
      def write(path)
        path.write(render)
      end

      # The same parts under other names — a release's, `<build>-<version>.<ext>`.
      #
      # @yieldparam name [String] a part's name as listed
      # @yieldreturn [String] its new name
      # @return [PartList]
      sig { params(blk: T.proc.params(name: String).returns(String)).returns(PartList) }
      def renamed(&blk)
        PartList.new(parts: parts.map { |part| Part.new(sha256: part.sha256, name: yield(part.name)) })
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [parts]
      end
    end
  end
end
