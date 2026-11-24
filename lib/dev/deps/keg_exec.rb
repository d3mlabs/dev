# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "toolchain_exec"

module Dev
  module Deps
    # The spawn seam for one keg's own binaries: `<keg>/bin/<program>`, by
    # path, with no project and no shadowenv in between. A self-contained
    # tree's gems vendor under the Ruby its own lock pins, which is a keg
    # dev installed and nothing the current project activates.
    #
    # Like ShadowenvExec, this seam clears nothing: the env it inherits is
    # the caller's, scrubbed once at bin/dev's entrypoint, and passes
    # through.
    class KegExec
      extend T::Sig
      include ToolchainExec

      # @param keg [Pathname] the keg's prefix (brew's Cellar/<formula>/<version>)
      sig { params(keg: Pathname).void }
      def initialize(keg:)
        @keg = keg
      end

      # Run one of the keg's binaries and capture its output.
      #
      # @param command [Array<String>] argv; the program is resolved under the keg's `bin`
      # @param env [Hash{String => String, nil}] caller env for the child, layered over the inherited one
      # @return [Array(String, String, Process::Status)] stdout, stderr, exit status
      sig do
        override.params(
          command: String,
          env: T::Hash[String, T.nilable(String)],
        ).returns([String, String, Process::Status])
      end
      def capture3(*command, env: {})
        program, *arguments = command
        # T.unsafe: Sorbet accepts a splat only of statically sized arrays.
        T.unsafe(Open3).capture3(env, (@keg / "bin" / T.must(program)).to_s, *arguments)
      end
    end
  end
end
