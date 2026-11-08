# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "archive"
require_relative "part_list"
require_relative "shell"

module Dev
  module Lifecycle
    # The inverse of Archive, for a publisher that must hand the destination
    # a directory rather than a file (dev#192, K5): Steam's content builder
    # reads a depot's content root, EGS's BuildPatchTool a build root. Reads
    # every form Archive writes — a zip, a `.tar.zst`, a split set through
    # its `MANIFEST` (`cat parts | zstd -d | tar -x`, the gh integration's
    # pipeline) — and tells them apart by the archive's extension, the one
    # fact the shipment carries about its form.
    #
    # The archive is read-only input: it is never moved or altered. The
    # destination is **replaced** — removed and recreated before the
    # extraction — so a content root is exactly the archive's contents and
    # a file the previous deploy shipped never rides along in this one.
    class Unpacker
      extend T::Sig

      # The archive does not exist.
      class MissingArchiveError < RuntimeError; end

      # The archive's extension names no form Archive writes.
      class UnknownArchiveFormatError < ArgumentError; end

      # `unzip`, `zstd` or `tar` ended other than with exit 0.
      class UnpackFailedError < RuntimeError; end

      # @param shell [Shell] the process boundary the pipelines run through
      sig { params(shell: Shell).void }
      def initialize(shell: Shell.new)
        @shell = shell
      end

      # Extract an archive into a directory of its own.
      #
      # @param archive [Pathname] a zip, a `.tar.zst`, or a split set's `MANIFEST`
      # @param into [Pathname] the directory to hold the contents; replaced
      # @return [Pathname] `into`
      # @raise [MissingArchiveError]
      # @raise [UnknownArchiveFormatError]
      # @raise [UnpackFailedError]
      # @raise [Shell::SpawnError] when `unzip`, `zstd` or `tar` is missing
      sig { params(archive: Pathname, into: Pathname).returns(Pathname) }
      def unpack(archive, into:)
        raise MissingArchiveError, "no archive at #{archive}" unless archive.file?

        FileUtils.rm_rf(into)
        into.mkpath
        name = archive.basename.to_s
        if name.end_with?(".#{Archive::Form::Zip::EXTENSION}")
          unzip(archive, into)
        elsif name.end_with?(".#{Archive::Form::Tar::EXTENSION}")
          untar([archive], into)
        elsif name.end_with?(".#{Archive::Form::Tar::MANIFEST_EXTENSION}")
          untar(PartList.read(archive).parts.map { |part| archive.dirname / part.name }, into)
        else
          raise UnknownArchiveFormatError,
            "#{name}: not an archive dev packs (.#{Archive::Form::Zip::EXTENSION}, .#{Archive::Form::Tar::EXTENSION} " \
              "or a split set's .#{Archive::Form::Tar::MANIFEST_EXTENSION})"
        end
        into
      end

      private

      # @param archive [Pathname]
      # @param into [Pathname]
      # @return [void]
      # @raise [UnpackFailedError]
      sig { params(archive: Pathname, into: Pathname).void }
      def unzip(archive, into)
        status = @shell.run(["unzip", "-q", "-o", archive.to_s, "-d", into.to_s], chdir: into)
        raise UnpackFailedError, "unzip of #{archive} #{Shell.describe(status)}" unless status.success?
      end

      # One pipeline for the whole and the split tar: `cat` of the parts
      # in order is the stream `zstd` and `tar` read.
      #
      # @param parts [Array<Pathname>] the `.tar.zst`, or its parts in order
      # @param into [Pathname]
      # @return [void]
      # @raise [UnpackFailedError] naming the first stage that failed
      sig { params(parts: T::Array[Pathname], into: Pathname).void }
      def untar(parts, into)
        commands = [["cat", *parts.map(&:to_s)], ["zstd", "-d", "-q", "-c", "-"], ["tar", "-x", "-C", into.to_s, "-f", "-"]]
        statuses = @shell.pipeline(commands, chdir: into)
        failed = statuses.index { |status| !status.success? }
        return if failed.nil?

        raise UnpackFailedError,
          "unpacking #{T.must(parts.first)}: `#{T.must(commands[failed]).first}` #{Shell.describe(T.must(statuses[failed]))}"
      end
    end
  end
end
