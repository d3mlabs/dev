# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"
require_relative "acceptance"
require_relative "byte_size"
require_relative "file_selection"
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
    # forms over a stage's contents:
    #
    # - zip (the default): `<build>.zip`, symlinks kept as symlinks.
    # - tar: `<build>.tar.zst`; with `split:`, cut into `<build>.tar.zst.00`,
    #   `.01`, … of at most that size, plus `<build>.MANIFEST` listing each
    #   part's SHA-256 in `sha256sum -c` form. GitHub's 2 GiB per release
    #   asset is the limit the split exists for.
    #
    # Which of the stage's files ship is its `files:` (FileSelection):
    # the whole stage unless the target lists patterns, the selected files
    # at their stage paths when it does. The selection — the tree as it
    # ships — is what the destinations are shown (Acceptance) before
    # anything is written; a refusal leaves the previous archive in place.
    #
    # Writes over its own previous output. The tar form needs `zstd` on
    # PATH, declared with the project's dependencies.
    class Archive
      extend T::Sig
      include Packager
      include Dev::ValueEquality::Derived

      # The directory to archive does not exist.
      class MissingDirectoryError < RuntimeError; end

      # The directory to archive holds nothing.
      class EmptyDirectoryError < RuntimeError; end

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

      sig { returns(FileSelection) }
      attr_reader :files

      # @param form [Form]
      # @param files [FileSelection] which of the stage's files ship; the whole stage by default
      # @param shell [Shell]
      sig { params(form: Form, files: FileSelection, shell: Shell).void }
      def initialize(form: Form::Zip.new, files: FileSelection.all, shell: Shell.new)
        @form = form
        @files = files
        @shell = shell
      end

      # The Packager port: the form does not depend on the build, so this
      # is #pack.
      #
      # @param build [Build] unused
      # @param stage [Pathname]
      # @param archive [Pathname]
      # @param acceptance [Acceptance] shown the selected tree before it is written
      # @return [PackedArchive]
      # @raise [MissingDirectoryError]
      # @raise [EmptyDirectoryError]
      # @raise [FileSelection::EmptySelectionError]
      # @raise [PackFailedError]
      # @raise [Shell::SpawnError]
      sig { override.params(build: Build, stage: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def package(build, stage, archive, acceptance: Acceptance.unconditional)
        _ = build
        pack(stage, archive, acceptance:)
      end

      # Archive a directory's contents in this form — what `dev pack` runs
      # over any directory, no build in sight.
      #
      # @param directory [Pathname] the directory whose contents are archived
      # @param archive [Pathname] the path without extension; its directory
      #   is created if absent, and its previous output removed
      # @param acceptance [Acceptance] the destinations shown the selected
      #   tree before anything is written; a refusal is theirs and leaves
      #   the previous output in place
      # @return [PackedArchive]
      # @raise [MissingDirectoryError]
      # @raise [EmptyDirectoryError]
      # @raise [FileSelection::EmptySelectionError] when `files:` selects nothing
      # @raise [PackFailedError]
      # @raise [Shell::SpawnError] when `zip`, `tar`, `zstd` or `split` is missing
      sig { params(directory: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def pack(directory, archive, acceptance: Acceptance.unconditional)
        raise MissingDirectoryError, "nothing to archive: no directory at #{directory}" unless directory.directory?
        raise EmptyDirectoryError, "nothing to archive: #{directory} is empty" if directory.children.empty?

        with_selected(directory) do |selected|
          acceptance.accept!(selected)
          archive.dirname.mkpath
          remove_previous(archive)
          write(selected, archive)
        end
      end

      # The declaration as `dev help` renders it.
      #
      # @return [String] `archive`, `archive (tar)`, `archive (tar, split 2GiB)`,
      #   `archive, files: bin lib`
      sig { returns(String) }
      def to_s
        "archive#{@form}#{@files}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [form, files]
      end

      private

      # The directory the pipelines read: the directory itself for the
      # whole selection; for a `files:` list, a scratch copy of the selected
      # files at their paths, gone once the block returns. A copy rather
      # than a file list fed to `zip -@` and `tar -T`: the three pipelines
      # then read one directory the same way, and a selected archive lays
      # out exactly as a whole one does, directory entries included. The
      # selection is decided before anything is written.
      #
      # @param directory [Pathname]
      # @yieldparam selected [Pathname] the directory to archive
      # @return [PackedArchive] the block's
      # @raise [FileSelection::EmptySelectionError]
      sig { params(directory: Pathname, block: T.proc.params(selected: Pathname).returns(PackedArchive)).returns(PackedArchive) }
      def with_selected(directory, &block)
        return yield(directory) if @files.whole?

        selected = @files.select(directory)
        Dir.mktmpdir("dev-archive-") do |scratch|
          selected.each do |relative|
            destination = Pathname(scratch) / relative
            destination.dirname.mkpath
            FileUtils.copy_entry(directory / relative, destination, true)
          end
          yield Pathname(scratch)
        end
      end

      # @param directory [Pathname] the directory archived
      # @param archive [Pathname] the path without extension
      # @return [PackedArchive]
      # @raise [PackFailedError]
      sig { params(directory: Pathname, archive: Pathname).returns(PackedArchive) }
      def write(directory, archive)
        form = @form
        case form
        when Form::Zip then pack_zip(directory, archive)
        when Form::Tar then form.split? ? pack_split_tar(directory, archive, T.must(form.split)) : pack_tar(directory, archive)
        else
          # simplecov:disable — the sealed form has no third variant; T.absurd keeps the static proof.
          T.absurd(form)
          # simplecov:enable
        end
      end

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

      # @param directory [Pathname]
      # @param archive [Pathname]
      # @return [PackedArchive]
      # @raise [PackFailedError]
      sig { params(directory: Pathname, archive: Pathname).returns(PackedArchive) }
      def pack_zip(directory, archive)
        zip = with(archive, Form::Zip::EXTENSION)
        # Run from inside the directory so entries are relative to its root;
        # -y keeps symlinks as symlinks, -q leaves the terminal to dev.
        status = @shell.run(["zip", "-r", "-q", "-y", zip.to_s, "."], chdir: directory)
        raise PackFailedError, "zip of #{directory} #{Shell.describe(status)}" unless status.success?

        PackedArchive.new(archive: zip)
      end

      # @param directory [Pathname]
      # @param archive [Pathname]
      # @return [PackedArchive]
      # @raise [PackFailedError]
      sig { params(directory: Pathname, archive: Pathname).returns(PackedArchive) }
      def pack_tar(directory, archive)
        tar = with(archive, Form::Tar::EXTENSION)
        run_pipeline([tar_stage(directory), ["zstd", "-q", "-T0", "-f", "-o", tar.to_s, "-"]], directory)
        PackedArchive.new(archive: tar)
      end

      # @param directory [Pathname]
      # @param archive [Pathname]
      # @param split [ByteSize] the part size
      # @return [PackedArchive] the MANIFEST, then the parts in order
      # @raise [PackFailedError]
      sig { params(directory: Pathname, archive: Pathname, split: ByteSize).returns(PackedArchive) }
      def pack_split_tar(directory, archive, split)
        prefix = "#{with(archive, Form::Tar::EXTENSION)}."
        run_pipeline(
          [
            tar_stage(directory),
            ["zstd", "-q", "-T0", "-c", "-"],
            ["split", "-d", "-a", PART_SUFFIX_DIGITS, "-b", split.bytes.to_s, "-", prefix],
          ],
          directory,
        )
        parts = parts_of(archive)
        manifest = with(archive, Form::Tar::MANIFEST_EXTENSION)
        PartList.of(parts).write(manifest)
        PackedArchive.new(archive: manifest, parts:)
      end

      # @param directory [Pathname]
      # @return [Array<String>] `tar` streaming the directory's contents
      sig { params(directory: Pathname).returns(Shell::Argv) }
      def tar_stage(directory)
        ["tar", "-C", directory.to_s, "-cf", "-", "."]
      end

      # @param commands [Array<Array<String>>]
      # @param directory [Pathname] named in the failure
      # @return [void]
      # @raise [PackFailedError] naming the first stage that failed
      sig { params(commands: T::Array[Shell::Argv], directory: Pathname).void }
      def run_pipeline(commands, directory)
        statuses = @shell.pipeline(commands, chdir: directory)
        failed = statuses.index { |status| !status.success? }
        return if failed.nil?

        raise PackFailedError,
          "archiving #{directory}: `#{T.must(commands[failed]).first}` #{Shell.describe(T.must(statuses[failed]))}"
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
