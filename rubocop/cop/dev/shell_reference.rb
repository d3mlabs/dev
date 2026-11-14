# typed: false
# frozen_string_literal: true

require "pathname"
require "rubocop"

module RuboCop
  module Cop
    module Dev
      # dev's one layering rule, held by the gate: the
      # shell — `Dev::Cli`, everything under lib/dev/cli/ — depends on the
      # features and the vocabulary under lib/dev; nothing there depends on
      # the shell. A `Dev::Cli::*` constant referenced from a feature file is
      # an offense, in any spelling Ruby resolves: a call, a sig, a `T.let`,
      # a cbase-anchored path, or `Cli::X` written inside `module Dev`.
      #
      # References are what the rule is about — what Ruby lets through —
      # not `require` lines, which miss a reference riding on a transitive
      # load. A comment is prose and stays the
      # layer-boundaries rule's business. Tests, bin/ and the bootstrap
      # files beside lib/dev name the shell freely: the rule is about the
      # production layers, and the shell is the one that composes them.
      #
      # @example
      #   # bad (lib/dev/operator_access.rb)
      #   sig { params(ui: Dev::Cli::UiImpl).void }
      #
      #   # good — the vocabulary, which lives beside the features
      #   sig { params(ui: Dev::Ui).void }
      class ShellReference < Base
        MSG = "`%<constant>s` is the shell's (`Dev::Cli`); a feature or the vocabulary under lib/dev may not reference it."

        # Where the features and the vocabulary live, and the shell inside them.
        FEATURES = %r{\Alib/dev(?:/|\z)}
        SHELL = %r{\Alib/dev/cli(?:/|\.rb\z)}

        # @!method shell_constant?(node)
        def_node_matcher :shell_constant?, <<~PATTERN
          {
            (const (const (const {nil? cbase} :Dev) :Cli) _)
            (const (const nil? :Cli) _)
          }
        PATTERN

        def on_const(node)
          return unless feature_file?
          return unless shell_constant?(node)

          add_offense(node, message: format(MSG, constant: node.const_name))
        end

        private

        # Under lib/dev and not the shell itself (lib/dev/cli.rb, lib/dev/cli/**).
        def feature_file?
          path = relative_path
          FEATURES.match?(path) && !SHELL.match?(path)
        end

        def relative_path
          Pathname(processed_source.file_path).relative_path_from(Pathname(config.base_dir_for_path_parameters)).to_s
        end
      end
    end
  end
end
