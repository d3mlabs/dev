# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/cli/command"
require "dev/lifecycle"

module Dev
  module Cli
    module Builtins
      # `dev pack DIR [--out STEM] [--format zip|tar] [--split SIZE]`: archive a
      # directory's contents in one of dev's own forms (Lifecycle::Archive) —
      # `<STEM>.zip` by default, `<STEM>.tar.zst` for the tar format, the
      # numbered parts plus `<STEM>.MANIFEST` with `--split`. STEM is the
      # archive path without its extension, `./<DIR's name>` unless given;
      # the files written are printed one per line. Plumbing for a target's
      # `package:` script that wants the default form with a twist (`dev
      # pack "$DEV_INSTALL" --out "$DEV_ARTIFACT"`), so hidden from the
      # listings.
      class PackCommand < BuiltinCommand
        extend T::Sig

        OUT_FLAG = "--out"
        FORMAT_FLAG = "--format"
        SPLIT_FLAG = "--split"
        USAGE = "usage: dev pack DIR [--out STEM] [--format zip|tar] [--split SIZE]"

        # Not exactly one DIR positional.
        class UsageError < ArgumentError; end

        # Builds the archive over the form the flags spelled.
        ArchiveFactory = T.type_alias { T.proc.params(form: Dev::Lifecycle::Archive::Form).returns(Dev::Lifecycle::Archive) }

        sig { params(archive_factory: ArchiveFactory, out: T.any(IO, StringIO)).void }
        def initialize(archive_factory: ->(form) { Dev::Lifecycle::Archive.new(form:) }, out: $stdout)
          super()
          @archive_factory = archive_factory
          @out = out
        end

        sig { override.returns(String) }
        def desc
          "Archive a directory in one of dev's forms (pack DIR [--out STEM] [--format zip|tar] [--split SIZE])"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Workflow
        end

        sig { override.returns(T::Boolean) }
        def hidden?
          true
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [
            Cli::Flag.new(OUT_FLAG, takes_value: true, desc: "the archive path without its extension (default: ./<DIR's name>)"),
            Cli::Flag.new(FORMAT_FLAG, takes_value: true, desc: "zip (default) or tar"),
            Cli::Flag.new(SPLIT_FLAG, takes_value: true, desc: "cut the tar form into parts of at most SIZE (2GiB, 500MiB)"),
          ]
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          raise UsageError, USAGE unless args.positionals.size == 1

          install = Pathname(args.positionals.fetch(0)).expand_path
          archive = @archive_factory.call(form(args))
          packed = archive.pack(install, stem(args, install))
          packed.files.each { |file| @out.puts file }
        end

        private

        # @param args [Cli::ParsedArgs]
        # @return [Dev::Lifecycle::Archive::Form]
        # @raise [Dev::Lifecycle::Archive::UnknownFormatError]
        # @raise [Dev::Lifecycle::ByteSize::InvalidByteSizeError]
        # @raise [Dev::Lifecycle::Archive::SplitNeedsTarError]
        sig { params(args: Cli::ParsedArgs).returns(Dev::Lifecycle::Archive::Form) }
        def form(args)
          split = args.value(SPLIT_FLAG)
          format = args.value(FORMAT_FLAG)
          # `--split` alone means the tar form, as `split:` does in dev.yml.
          format ||= Dev::Lifecycle::Archive::Format::Tar.serialize if split
          Dev::Lifecycle::Archive::Form.for(
            format: format ? Dev::Lifecycle::Archive::Format.parse(format) : Dev::Lifecycle::Archive::Format::Zip,
            split: split ? Dev::Lifecycle::ByteSize.parse(split) : nil,
          )
        end

        # @param args [Cli::ParsedArgs]
        # @param install [Pathname] the directory being archived
        # @return [Pathname] the archive path without extension
        sig { params(args: Cli::ParsedArgs, install: Pathname).returns(Pathname) }
        def stem(args, install)
          out = args.value(OUT_FLAG)
          out ? Pathname(out).expand_path : Pathname.pwd / install.basename
        end
      end
    end
  end
end
