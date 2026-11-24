# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "acceptance"
require_relative "build"
require_relative "packager"
require_relative "packed_archive"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The built-in `as-is` packager: the stage already is the archive
    # (Alpakit's per-target zip, `gem build`'s `.gem`), so the one file the
    # builder left in the stage is copied under the build's name with its
    # own extension. Copied, not moved: the stage stays the builder's.
    class AsIsPackager
      extend T::Sig
      include Packager
      include Dev::ValueEquality::Derived

      # The stage does not exist or holds no file.
      class NoStageFileError < RuntimeError; end

      # The stage holds more than one file: nothing says which is the
      # archive.
      class AmbiguousStageError < RuntimeError; end

      # @param build [Build] unused: the adopted file carries its own extension
      # @param stage [Pathname] the directory holding exactly one file
      # @param archive [Pathname] the path without extension; its directory
      #   is created if absent
      # @param acceptance [Acceptance] unused: a file is adopted, there is no tree to present
      # @return [PackedArchive]
      # @raise [NoStageFileError]
      # @raise [AmbiguousStageError]
      sig { override.params(build: Build, stage: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def package(build, stage, archive, acceptance: Acceptance.unconditional)
        _ = [build, acceptance]
        source = the_one_file(stage)
        target = Pathname("#{archive}#{extension_of(source)}")
        target.dirname.mkpath
        FileUtils.cp(source, target)
        PackedArchive.new(archive: target)
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s
        "as-is"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        []
      end

      private

      # @param stage [Pathname]
      # @return [Pathname]
      # @raise [NoStageFileError]
      # @raise [AmbiguousStageError]
      sig { params(stage: Pathname).returns(Pathname) }
      def the_one_file(stage)
        files = stage.directory? ? stage.children.select(&:file?).sort : []
        raise NoStageFileError, "as-is: #{stage} holds no file to adopt as the archive" if files.empty?
        return T.must(files.first) if files.one?

        raise AmbiguousStageError,
          "as-is: #{stage} holds #{files.size} files (#{files.map(&:basename).join(", ")}); the stage must be one archive"
      end

      # The file's extension, keeping `.tar.<compression>` whole.
      #
      # @param file [Pathname]
      # @return [String] with the leading dot; empty for none
      sig { params(file: Pathname).returns(String) }
      def extension_of(file)
        extension = file.extname
        name = file.basename.to_s
        name.end_with?(".tar#{extension}") && extension != ".tar" ? ".tar#{extension}" : extension
      end
    end
  end
end
