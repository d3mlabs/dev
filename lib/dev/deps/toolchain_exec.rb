# typed: strict
# frozen_string_literal: true

module Dev
  module Deps
    # The spawn seam for a subprocess that must run under one Ruby toolchain
    # rather than whatever the dev process's PATH carries. Two toolchains
    # answer it: the project's provisioned one (ShadowenvExec, through the
    # project shadowenv) and one keg's own binaries (KegExec, by path). A
    # caller that materializes gems holds the seam, never the toolchain, so
    # `bundle install` is written once and runs under either.
    module ToolchainExec
      extend T::Sig
      extend T::Helpers
      interface!

      # Run a command under the toolchain and capture its output.
      #
      # @param command [Array<String>] argv, the program first
      # @param env [Hash{String => String, nil}] caller env for the child, layered over the inherited one
      # @return [Array(String, String, Process::Status)] stdout, stderr, exit status
      sig do
        abstract.params(
          command: String,
          env: T::Hash[String, T.nilable(String)],
        ).returns([String, String, Process::Status])
      end
      def capture3(*command, env: {}); end
    end
  end
end
