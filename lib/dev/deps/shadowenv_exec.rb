# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Deps
    # The one spawn seam for subprocesses that must run under the project's
    # provisioned Ruby toolchain: `shadowenv exec -- <command>` in the
    # project root, with dev's own Ruby activation scrubbed from the child.
    #
    # Both halves are load-bearing. The dev process's PATH is the invoking
    # shell's — headless services (CI, runners) have no shadowenv hook — so a
    # bare `bundle` or `gem` would resolve to whatever Ruby the host carries;
    # `shadowenv exec` swaps in the project's. But `shadowenv exec` applies
    # the project env only when it is not already active: invoked from a
    # shell whose hook already loaded this project (the normal interactive
    # case), it is a no-op that hands the child the env it inherited. Dev's
    # own activation would then reach bundler unchanged — the Homebrew
    # wrapper's GEM_HOME pointing into the dev-core Cellar, so `bundle
    # install` writes the project's gems there (dev#180); a sandboxed
    # harness's BUNDLE_PATH redirecting resolution into its ephemeral cache
    # (dev#89). Baking the scrub into the seam means no bundler or gem
    # shell-out has to remember it.
    class ShadowenvExec
      extend T::Sig

      # Env dev's own Ruby activation (or a harness's) may carry; each is
      # explicitly unset in the child so bundler resolves from the project's
      # canonical config. Dev never runs under bundler itself, so this is its
      # equivalent of Bundler.original_env.
      RUBY_ENV_SCRUB = T.let(
        [
          "BUNDLE_PATH",
          "BUNDLE_APP_CONFIG",
          "BUNDLE_BIN",
          "GEM_HOME",
          "GEM_PATH",
          "RUBYOPT",
          "RUBYLIB",
        ].to_h { |name| [name, nil] }.freeze,
        T::Hash[String, T.nilable(String)],
      )

      # @param project_root [Pathname, String] root whose shadowenv the child runs under
      sig { params(project_root: T.any(String, Pathname)).void }
      def initialize(project_root:)
        @project_root = T.let(Pathname(project_root), Pathname)
      end

      # Run a command under the project's toolchain and capture its output.
      #
      # @param command [Array<String>] argv to run under `shadowenv exec --`
      # @param env [Hash{String => String, nil}] caller env for the child, layered over the scrub
      # @return [Array(String, String, Process::Status)] stdout, stderr, exit status
      sig do
        params(
          command: String,
          env: T::Hash[String, T.nilable(String)],
        ).returns([String, String, Process::Status])
      end
      def capture3(*command, env: {})
        argv = ["shadowenv", "exec", "--", *command]
        T.unsafe(Open3).capture3(RUBY_ENV_SCRUB.merge(env), *argv, chdir: @project_root.to_s)
      end
    end
  end
end
