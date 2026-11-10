# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"

module Dev
  module Lifecycle
    # The `MANIFEST` of a split archive (dev#192, K1): one line per part,
    # `<sha256>  <part file name>`, in part order — the shape `sha256sum
    # -c` reads, so a reader checks a downloaded set with the tool it has.
    # The one spelling of that file for the three places that touch it:
    # the Archive writes it beside the parts it split, ReleaseAssets
    # rewrites it under the parts' release names, and a release's download
    # (ReleaseArchives, dev#425) reads it to know which parts to fetch and
    # what each must hash to.
    class PartList < T::Struct
      extend T::Sig

      # A line that is not `<sha256>  <part>`.
      class MalformedPartListError < RuntimeError; end

      # One part: its digest and its file name, as listed.
      class Part < T::Struct
        extend T::Sig

        const :sha256, String
        const :name, String

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Part) && sha256 == other.sha256 && name == other.name
        end

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig { returns(Integer) }
        def hash
          [Part, sha256, name].hash
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

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(PartList) && parts == other.parts
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [PartList, parts].hash
      end
    end
  end
end
