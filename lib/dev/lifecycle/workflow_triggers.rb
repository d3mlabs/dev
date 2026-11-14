# typed: strict
# frozen_string_literal: true

require "pathname"
require "yaml"

module Dev
  module Lifecycle
    # The project's GitHub workflows read for one question: would pushing
    # a snapshot branch run any of them? A workflow with an `on: push` that
    # no branch filter excludes would run CI on every remote dispatch, so
    # the sync step asks before it pushes anything and refuses with the fix.
    #
    # The answer is GitHub's own: a push trigger runs for a branch when it
    # has no `branches` / `branches-ignore` / `tags` / `tags-ignore` filter
    # at all, when its `branches` match the name (`!` negations in order),
    # or when its `branches-ignore` do not; a trigger filtered on tags only
    # never runs for a branch. Path filters do not narrow branches and are
    # ignored.
    class WorkflowTriggers
      extend T::Sig

      # A workflow whose push trigger would run for the snapshot branch.
      class UnfilteredPushTriggerError < RuntimeError; end

      # A workflow file that is not YAML, or not a mapping.
      class MalformedWorkflowError < RuntimeError; end

      WORKFLOWS_DIR = ".github/workflows"
      WORKFLOW_GLOBS = T.let(["*.yml", "*.yaml"].freeze, T::Array[String])
      # Psych reads a bare `on` key as YAML 1.1's boolean, so a workflow's
      # trigger block arrives under `true`, not `"on"`; a quoted `"on":`
      # arrives as the string.
      ON_KEYS = T.let(["on", true].freeze, T::Array[T.any(String, T::Boolean)])
      PUSH_EVENT = "push"

      # One pattern of a `branches` / `branches-ignore` list, in GitHub's
      # filter grammar: `*` is anything but `/`, `**` is anything, `?` and
      # `+` quantify the preceding character, `[…]` is a class, a leading
      # `!` negates, `\` escapes. Anchored over the whole short branch name.
      class FilterPattern
        extend T::Sig

        # @return [Boolean] whether the pattern starts with `!`
        sig { returns(T::Boolean) }
        attr_reader :negated

        # @param source [String] the pattern as written in the workflow
        sig { params(source: String).void }
        def initialize(source)
          @negated = T.let(source.start_with?("!"), T::Boolean)
          @regexp = T.let(self.class.to_regexp(source.delete_prefix("!")), Regexp)
        end

        # @param name [String] a short branch name
        # @return [Boolean]
        sig { params(name: String).returns(T::Boolean) }
        def matches?(name)
          @regexp.match?(name)
        end

        class << self
          extend T::Sig

          # @param glob [String] the pattern without its negation
          # @return [Regexp]
          sig { params(glob: String).returns(Regexp) }
          def to_regexp(glob)
            chars = glob.chars
            body = +""
            index = 0
            while index < chars.length
              char = T.must(chars[index])
              case char
              when "\\"
                index += 1
                body << Regexp.escape(chars[index].to_s)
              when "*"
                if chars[index + 1] == "*"
                  body << ".*"
                  index += 1
                else
                  body << "[^/]*"
                end
              when "?", "+", "[", "]", "-"
                # The same meaning in GitHub's grammar and Ruby's regexp.
                body << char
              else
                body << Regexp.escape(char)
              end
              index += 1
            end
            /\A#{body}\z/
          end
        end
      end

      # A workflow's `push` trigger, reduced to what decides whether a
      # branch push runs it.
      class PushTrigger < T::Struct
        extend T::Sig

        const :branches, T.nilable(T::Array[FilterPattern])
        const :branches_ignore, T.nilable(T::Array[FilterPattern])
        # Whether a `tags` / `tags-ignore` filter is present: with no
        # branch filter beside it, the trigger is for tags only.
        const :tag_filtered, T::Boolean

        # @param name [String] a short branch name
        # @return [Boolean] whether a push to that branch runs the workflow
        sig { params(name: String).returns(T::Boolean) }
        def fires_on?(name)
          return self.class.ordered_match?(T.must(branches), name) if branches
          return T.must(branches_ignore).none? { |pattern| pattern.matches?(name) } if branches_ignore

          !tag_filtered
        end

        class << self
          extend T::Sig

          # GitHub evaluates a `branches` list in order: a positive match
          # includes, a later `!` match excludes, a later positive match
          # includes again.
          #
          # @param patterns [Array<FilterPattern>]
          # @param name [String]
          # @return [Boolean]
          sig { params(patterns: T::Array[FilterPattern], name: String).returns(T::Boolean) }
          def ordered_match?(patterns, name)
            patterns.reduce(false) do |included, pattern|
              next included unless pattern.matches?(name)

              !pattern.negated
            end
          end
        end
      end

      # @param root [Pathname] the project root
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
      end

      # The workflows a push to a branch would run.
      #
      # @param branch_name [String] the short branch name
      # @return [Array<Pathname>] relative to the root, in file order
      # @raise [MalformedWorkflowError]
      sig { params(branch_name: String).returns(T::Array[Pathname]) }
      def firing_on_push_to(branch_name)
        workflow_files.select do |path|
          trigger = push_trigger(path)
          trigger ? trigger.fires_on?(branch_name) : false
        end.map { |path| path.relative_path_from(@root) }
      end

      # Refuse, with the fix, when any workflow would run for the branch.
      #
      # @param branch_name [String] the short branch name
      # @return [void]
      # @raise [UnfilteredPushTriggerError]
      # @raise [MalformedWorkflowError]
      sig { params(branch_name: String).void }
      def assert_none_fire_on_push_to!(branch_name)
        firing = firing_on_push_to(branch_name)
        return if firing.empty?

        raise UnfilteredPushTriggerError,
          "pushing the snapshot branch #{branch_name} would run #{firing.join(", ")}: " \
            "the `on: push` trigger has no branch filter that excludes it. " \
            "Filter it on the project's branches (`on: push: branches: [main]`) " \
            "or exclude dev's namespace (`branches-ignore: ['dev/build/**']`)"
      end

      private

      # @return [Array<Pathname>] every workflow file, sorted
      sig { returns(T::Array[Pathname]) }
      def workflow_files
        dir = @root / WORKFLOWS_DIR
        WORKFLOW_GLOBS.flat_map { |glob| Pathname.glob(dir / glob) }.sort
      end

      # @param path [Pathname] a workflow file
      # @return [PushTrigger, nil] nil when the workflow has no push trigger
      # @raise [MalformedWorkflowError]
      sig { params(path: Pathname).returns(T.nilable(PushTrigger)) }
      def push_trigger(path)
        document = YAML.safe_load(path.read, permitted_classes: [Symbol], aliases: true)
        raise MalformedWorkflowError, "#{path.relative_path_from(@root)}: expected a mapping" unless document.is_a?(Hash)

        on = ON_KEYS.filter_map { |key| document[key] }.first
        case on
        when String then on == PUSH_EVENT ? unfiltered_trigger : nil
        when Array then on.include?(PUSH_EVENT) ? unfiltered_trigger : nil
        when Hash then on.key?(PUSH_EVENT) ? trigger_from(on[PUSH_EVENT]) : nil
        end
      rescue Psych::SyntaxError => e
        raise MalformedWorkflowError, "#{path.relative_path_from(@root)}: #{e.message}"
      end

      # @return [PushTrigger] `on: push` with nothing narrowing it
      sig { returns(PushTrigger) }
      def unfiltered_trigger
        PushTrigger.new(branches: nil, branches_ignore: nil, tag_filtered: false)
      end

      # @param config [Object] the value under `push:` — nil, `{}` or the filters
      # @return [PushTrigger]
      sig { params(config: T.untyped).returns(PushTrigger) }
      def trigger_from(config)
        return unfiltered_trigger unless config.is_a?(Hash)

        PushTrigger.new(
          branches: patterns(config["branches"]),
          branches_ignore: patterns(config["branches-ignore"]),
          tag_filtered: config.key?("tags") || config.key?("tags-ignore"),
        )
      end

      # @param value [Object] a filter list as written: a string, a list, or absent
      # @return [Array<FilterPattern>, nil]
      sig { params(value: T.untyped).returns(T.nilable(T::Array[FilterPattern])) }
      def patterns(value)
        return if value.nil?

        Array(value).map { |pattern| FilterPattern.new(pattern.to_s) }
      end
    end
  end
end
