# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "flag"
require_relative "parsed_args"

module Dev
  module Cli
    # What `dev build` and `dev package` make of their argv:
    # one Build. The positional is a build name or a pattern in the grammar
    # (`<target>[-<platform>[-<config>]]`); `--target T --platform P
    # --config C` is its long form; an axis the argument leaves out takes
    # the target's first declared value — so `dev build cellbound-3d` is the
    # client's default platform and config, and bare `dev build` is the
    # first declared target's default build, which is why a project lists
    # its fast-loop target first. The verbs' flags are consumed here and
    # never reach a seam.
    #
    # The project's targets are fixed for a run and constructor-owned; the
    # args are per call.
    class BuildSelector
      extend T::Sig

      TARGET_FLAG = "--target"
      PLATFORM_FLAG = "--platform"
      CONFIG_FLAG = "--config"

      # The flags of every verb that names a build; a verb appends its own.
      FLAGS = T.let(
        [
          Cli::Flag.new(TARGET_FLAG, takes_value: true, desc: "the target (the long form of the BUILD positional)"),
          Cli::Flag.new(PLATFORM_FLAG, takes_value: true, desc: "one of the target's platforms (default: its first)"),
          Cli::Flag.new(CONFIG_FLAG, takes_value: true, desc: "one of the target's configs (default: its first)"),
        ].freeze,
        T::Array[Cli::Flag],
      )

      # More than one positional: a verb acts on one build.
      class TooManyBuildsError < ArgumentError; end

      # The build was named twice — a positional beside `--target`, or an
      # axis both in the positional's name and as its flag.
      class ConflictingSelectionError < ArgumentError; end

      # @return [Array<Lifecycle::Target>] the project's targets, in declaration order
      sig { returns(T::Array[Lifecycle::Target]) }
      attr_reader :targets

      # @param targets [Array<Lifecycle::Target>] non-empty: the verbs exist
      #   only when the project declares targets
      sig { params(targets: T::Array[Lifecycle::Target]).void }
      def initialize(targets:)
        @targets = targets
      end

      # The build the args name.
      #
      # @param args [Cli::ParsedArgs] parsed against FLAGS (and the verb's own)
      # @return [Lifecycle::Build]
      # @raise [TooManyBuildsError]
      # @raise [ConflictingSelectionError]
      # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the grammar's
      #   other errors, for a name no target admits
      # @raise [Lifecycle::UnknownPlatformError, Lifecycle::UnknownConfigError]
      #   for a flag value outside the id sets
      # @raise [Lifecycle::Build::PlatformMismatchError,
      #   Lifecycle::Build::ConfigMismatchError] for a flag value the target
      #   does not declare
      sig { params(args: Cli::ParsedArgs).returns(Lifecycle::Build) }
      def select(args)
        pattern = base_pattern(args)
        platform = axis_value(args, PLATFORM_FLAG, pattern.platform) { |id| Lifecycle::Platform.parse(id) }
        config = axis_value(args, CONFIG_FLAG, pattern.config) { |id| Lifecycle::Config.parse(id) }
        Lifecycle::BuildPattern.new(target: pattern.target, platform:, config:).default_build
      end

      private

      # The pattern the positional or `--target` spells — the first target,
      # bare, when neither is given.
      #
      # @param args [Cli::ParsedArgs]
      # @return [Lifecycle::BuildPattern]
      # @raise [TooManyBuildsError]
      # @raise [ConflictingSelectionError]
      sig { params(args: Cli::ParsedArgs).returns(Lifecycle::BuildPattern) }
      def base_pattern(args)
        positional = args.positionals.first
        if args.positionals.size > 1
          raise TooManyBuildsError, "one build at a time: got #{args.positionals.map(&:inspect).join(", ")}"
        end

        target = args.value(TARGET_FLAG)
        if positional && target
          raise ConflictingSelectionError, "the build is named twice: '#{positional}' and #{TARGET_FLAG} #{target}"
        end

        name = positional || target || T.must(@targets.first).name
        Lifecycle::BuildPattern.parse(name, @targets)
      end

      # One axis: the flag's value parsed, the pattern's own, or nil for the
      # target's default — never both the pattern's and the flag's.
      #
      # @param args [Cli::ParsedArgs]
      # @param flag [String] PLATFORM_FLAG or CONFIG_FLAG
      # @param from_pattern [Platform, Config, nil] what the positional spelled
      # @yieldparam id [String] the flag's value
      # @yieldreturn [Platform, Config] the parsed id
      # @return [Platform, Config, nil]
      # @raise [ConflictingSelectionError]
      sig do
        type_parameters(:Axis)
          .params(
            args: Cli::ParsedArgs,
            flag: String,
            from_pattern: T.nilable(T.type_parameter(:Axis)),
            blk: T.proc.params(id: String).returns(T.type_parameter(:Axis)),
          ).returns(T.nilable(T.type_parameter(:Axis)))
      end
      def axis_value(args, flag, from_pattern, &blk)
        value = args.value(flag)
        return from_pattern if value.nil?
        return yield(value) unless from_pattern

        raise ConflictingSelectionError, "the #{flag.delete_prefix("--")} is named twice: '#{from_pattern}' in the build and #{flag} #{value}"
      end
    end
  end
end
