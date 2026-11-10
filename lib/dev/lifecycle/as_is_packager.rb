# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "build"
require_relative "packager"
require_relative "packed_archive"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The built-in `as-is` packager (dev#192, K1): the install already *is*
    # the archive — Alpakit's per-target zip, `gem build`'s `.gem` — so the
    # one file the builder left in the install directory is adopted under
    # the build's name with its own extension (`<build>.zip`, `<build>.gem`,
    # `<build>.tar.zst`). Copied, not moved: the install stays the
    # builder's, incremental state included.
    class AsIsPackager
      extend T::Sig
      include Packager
      include Dev::ValueEquality::Derived

      # The install directory does not exist or holds no file.
      class NoInstallFileError < RuntimeError; end

      # The install directory holds more than one file: nothing says which
      # is the archive.
      class AmbiguousInstallError < RuntimeError; end

      # @param build [Build] unused: the adopted file carries its own extension
      # @param install [Pathname] the directory holding exactly one file
      # @param archive [Pathname] the path without extension; its directory
      #   is created if absent
      # @return [PackedArchive]
      # @raise [NoInstallFileError]
      # @raise [AmbiguousInstallError]
      sig { override.params(build: Build, install: Pathname, archive: Pathname).returns(PackedArchive) }
      def package(build, install, archive)
        _ = build
        source = the_one_file(install)
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

      # @param install [Pathname]
      # @return [Pathname]
      # @raise [NoInstallFileError]
      # @raise [AmbiguousInstallError]
      sig { params(install: Pathname).returns(Pathname) }
      def the_one_file(install)
        files = install.directory? ? install.children.select(&:file?).sort : []
        raise NoInstallFileError, "as-is: #{install} holds no file to adopt as the archive" if files.empty?
        return T.must(files.first) if files.one?

        raise AmbiguousInstallError,
          "as-is: #{install} holds #{files.size} files (#{files.map(&:basename).join(", ")}); the install must be one archive"
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
