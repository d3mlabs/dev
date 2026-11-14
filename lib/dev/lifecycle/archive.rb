# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "byte_size"
require_relative "packager"
require_relative "packed_archive"
require_relative "part_list"
require_relative "shell"
require_relative "../value_equality"
# Build appears in a signature only; see packager.rb for why build.rb is
# not required here.

module Dev
  module Lifecycle
    # The built-in `archive` packager, the default for every target that
    # declares no other, and what `dev pack` runs over any directory. Two
    # forms over an install directory's contents:
    #
    # - zip (the default): `<build>.zip`, symlinks kept as symlinks.
    # - tar: `<build>.tar.zst`; with `split:`, cut into `<build>.tar.zst.00`,
    #   `.01`, … of at most that size, plus `<build>.MANIFEST` listing each
    #   part's SHA-256 in `sha256sum -c` form. GitHub's 2 GiB per release
    #   asset is the limit the split exists for.
    #
    # Writes over its own previous output. The tar form needs `zstd` on
    # PATH, declared with the project's dependencies.
    class Archive
      extend T::Sig
      include Packager
      include Dev::ValueEquality::Derived

      # The install directory does not exist.
      class MissingInstallError < RuntimeError; end

      # The install directory holds nothing to archive.
      class EmptyInstallError < RuntimeError; end

      # A stage of the archive pipeline failed.
      class PackFailedError < RuntimeError; end

      # An id outside Format's set. Beside the enum: a T::Enum body may
      # hold only its own values.
      class UnknownFormatError < ArgumentError; end

      # `split:` given with the zip format, which has no split form here.
      class SplitNeedsTarError < ArgumentError; end

      # The two formats, as dev.yml and `dev pack --format` spell them.
      class Format < T::Enum
        extend T::Sig

        enums do
          Zip = new("zip")
          Tar = new("tar")
        end

        class << self
          extend T::Sig

          # @param id [String]
          # @return [Format]
          # @raise [UnknownFormatError]
          sig { params(id: String).returns(Format) }
          def parse(id)
            try_deserialize(id) || raise(UnknownFormatError, "unknown archive format #{id.inspect} (expected #{ids.join(", ")})")
          end

          # @return [Array<String>]
          sig { returns(T::Array[String]) }
          def ids
            values.map(&:serialize)
          end
        end
      end

      # The form an archive takes: a zip, or a tar — whole or split. Sealed
      # so that a split zip is unrepresentable rather than checked.
      module Form
        extend T::Sig
        extend T::Helpers
        include Kernel
        abstract!
        sealed!

        class << self
          extend T::Sig

          # The form a format id and an optional `split:` spell — the one
          # site of the "split needs tar" rule, shared by dev.yml and `dev
          # pack`.
          #
          # @param format [Format]
          # @param split [ByteSize, nil]
          # @return [Form]
          # @raise [SplitNeedsTarError]
          sig { params(format: Format, split: T.nilable(ByteSize)).returns(Form) }
          def for(format:, split: nil)
            case format
            when Format::Zip
              raise SplitNeedsTarError, "archive: `split:` needs the tar format (format: tar)" if split

              Zip.new
            when Format::Tar then Tar.new(split:)
            else
              # simplecov:disable — the enum has no third value; T.absurd keeps the static proof.
              T.absurd(format)
              # simplecov:enable
            end
          end
        end

        # The extension of the file that stands for the archive.
        sig { abstract.returns(String) }
        def extension; end

        # The form as `dev help` renders it after `archive`.
        sig { abstract.returns(String) }
        def to_s; end

        # `<build>.zip`.
        class Zip < T::Struct
          extend T::Sig
          include Form
          include Dev::ValueEquality::Derived

          EXTENSION = "zip"

          sig { override.returns(String) }
          def extension
            EXTENSION
          end

          sig { override.returns(String) }
          def to_s
            ""
          end
          # @return [Array] the members that constitute identity
          sig { override.returns(T::Array[T.anything]) }
          def equality_members
            []
          end
        end

        # `<build>.tar.zst`, or with `split` the parts of at most that size
        # plus `<build>.MANIFEST`.
        class Tar < T::Struct
          extend T::Sig
          include Form
          include Dev::ValueEquality::Derived

          EXTENSION = "tar.zst"
          MANIFEST_EXTENSION = "MANIFEST"

          const :split, T.nilable(ByteSize), default: nil

          sig { returns(T::Boolean) }
          def split?
            !split.nil?
          end

          sig { override.returns(String) }
          def extension
            split? ? MANIFEST_EXTENSION : EXTENSION
          end

          sig { override.returns(String) }
          def to_s
            split? ? " (tar, split #{split})" : " (tar)"
          end
          # @return [Array] the members that constitute identity
          sig { override.returns(T::Array[T.anything]) }
          def equality_members
            [split]
          end
        end
      end

      # Two digits, as the gh integration's reader groups (`x.tar.zst.01`).
      PART_SUFFIX_DIGITS = "2"

      sig { returns(Form) }
      attr_reader :form

      # @param form [Form]
      # @param shell [Shell]
      sig { params(form: Form, shell: Shell).void }
      def initialize(form: Form::Zip.new, shell: Shell.new)
        @form = form
        @shell = shell
      end

      # The Packager port: the form does not depend on the build, so this
      # is #pack.
      #
      # @param build [Build] unused
      # @param install [Pathname]
      # @param archive [Pathname]
      # @return [PackedArchive]
      # @raise [MissingInstallError]
      # @raise [EmptyInstallError]
      # @raise [PackFailedError]
      # @raise [Shell::SpawnError]
      sig { override.params(build: Build, install: Pathname, archive: Pathname).returns(PackedArchive) }
      def package(build, install, archive)
        _ = build
        pack(install, archive)
      end

      # Archive a directory's contents in this form — what `dev pack` runs
      # over any directory, no build in sight.
      #
      # @param install [Pathname] the directory whose contents are archived
      # @param archive [Pathname] the path without extension; its directory
      #   is created if absent, and its previous output removed
      # @return [PackedArchive]
      # @raise [MissingInstallError]
      # @raise [EmptyInstallError]
      # @raise [PackFailedError]
      # @raise [Shell::SpawnError] when `zip`, `tar`, `zstd` or `split` is missing
      sig { params(install: Pathname, archive: Pathname).returns(PackedArchive) }
      def pack(install, archive)
        raise MissingInstallError, "no install at #{install}" unless install.directory?
        raise EmptyInstallError, "nothing to archive: #{install} is empty" if install.children.empty?

        archive.dirname.mkpath
        remove_previous(archive)
        form = @form
        case form
        when Form::Zip then pack_zip(install, archive)
        when Form::Tar then form.split? ? pack_split_tar(install, archive, T.must(form.split)) : pack_tar(install, archive)
        else
          # simplecov:disable — the sealed form has no third variant; T.absurd keeps the static proof.
          T.absurd(form)
          # simplecov:enable
        end
      end

      # The declaration as `dev help` renders it.
      #
      # @return [String] `archive`, `archive (tar)`, `archive (tar, split 2GiB)`
      sig { returns(String) }
      def to_s
        "archive#{@form}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [form]
      end

      private

      # Every file a previous packaging of this archive could have left:
      # the zip, the tar, the parts and the MANIFEST.
      #
      # @param archive [Pathname]
      # @return [void]
      sig { params(archive: Pathname).void }
      def remove_previous(archive)
        previous = [Form::Zip::EXTENSION, Form::Tar::EXTENSION, Form::Tar::MANIFEST_EXTENSION].map { |ext| with(archive, ext) }
        (previous + parts_of(archive)).select(&:file?).each(&:delete)
      end

      # @param install [Pathname]
      # @param archive [Pathname]
      # @return [PackedArchive]
      # @raise [PackFailedError]
      sig { params(install: Pathname, archive: Pathname).returns(PackedArchive) }
      def pack_zip(install, archive)
        zip = with(archive, Form::Zip::EXTENSION)
        # Run from inside the install so entries are relative to its root;
        # -y keeps symlinks as symlinks, -q leaves the terminal to dev.
        status = @shell.run(["zip", "-r", "-q", "-y", zip.to_s, "."], chdir: install)
        raise PackFailedError, "zip of #{install} #{Shell.describe(status)}" unless status.success?

        PackedArchive.new(archive: zip)
      end

      # @param install [Pathname]
      # @param archive [Pathname]
      # @return [PackedArchive]
      # @raise [PackFailedError]
      sig { params(install: Pathname, archive: Pathname).returns(PackedArchive) }
      def pack_tar(install, archive)
        tar = with(archive, Form::Tar::EXTENSION)
        run_pipeline([tar_stage(install), ["zstd", "-q", "-T0", "-f", "-o", tar.to_s, "-"]], install)
        PackedArchive.new(archive: tar)
      end

      # @param install [Pathname]
      # @param archive [Pathname]
      # @param split [ByteSize] the part size
      # @return [PackedArchive] the MANIFEST, then the parts in order
      # @raise [PackFailedError]
      sig { params(install: Pathname, archive: Pathname, split: ByteSize).returns(PackedArchive) }
      def pack_split_tar(install, archive, split)
        prefix = "#{with(archive, Form::Tar::EXTENSION)}."
        run_pipeline(
          [
            tar_stage(install),
            ["zstd", "-q", "-T0", "-c", "-"],
            ["split", "-d", "-a", PART_SUFFIX_DIGITS, "-b", split.bytes.to_s, "-", prefix],
          ],
          install,
        )
        parts = parts_of(archive)
        manifest = with(archive, Form::Tar::MANIFEST_EXTENSION)
        PartList.of(parts).write(manifest)
        PackedArchive.new(archive: manifest, parts:)
      end

      # @param install [Pathname]
      # @return [Array<String>] `tar` streaming the install's contents
      sig { params(install: Pathname).returns(Shell::Argv) }
      def tar_stage(install)
        ["tar", "-C", install.to_s, "-cf", "-", "."]
      end

      # @param commands [Array<Array<String>>]
      # @param install [Pathname] named in the failure
      # @return [void]
      # @raise [PackFailedError] naming the first stage that failed
      sig { params(commands: T::Array[Shell::Argv], install: Pathname).void }
      def run_pipeline(commands, install)
        statuses = @shell.pipeline(commands, chdir: install)
        failed = statuses.index { |status| !status.success? }
        return if failed.nil?

        raise PackFailedError,
          "archiving #{install}: `#{T.must(commands[failed]).first}` #{Shell.describe(T.must(statuses[failed]))}"
      end

      # @param archive [Pathname]
      # @return [Array<Pathname>] the split parts present, in order
      sig { params(archive: Pathname).returns(T::Array[Pathname]) }
      def parts_of(archive)
        Pathname.glob("#{with(archive, Form::Tar::EXTENSION)}.[0-9]*").select(&:file?).sort
      end

      # @param archive [Pathname] the path without extension
      # @param extension [String]
      # @return [Pathname]
      sig { params(archive: Pathname, extension: String).returns(Pathname) }
      def with(archive, extension)
        Pathname("#{archive}.#{extension}")
      end
    end
  end
end
