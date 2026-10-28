# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Deps
    # The spawn seam for subprocesses that must run under the project's
    # provisioned toolchain: `shadowenv exec -- <command>` in the project
    # root. The dev process's PATH is the invoking shell's — headless
    # services (CI, runners) have no shadowenv hook — so a bare `bundle` or
    # `gem` would resolve to whatever Ruby the host carries; `shadowenv
    # exec` swaps in the project's.
    #
    # Env hygiene is not this seam's job, and it clears nothing. A caller's
    # hostile activation (a harness's `bundle exec`, a sandbox's
    # BUNDLE_PATH) is stripped once, at bin/dev's entrypoint, before any
    # Ruby exists; an installed dev selects its own vendored gems in-process
    # and exports nothing. So the env this seam inherits is the caller's,
    # clean, and it passes through: in a project shell that is the
    # activation itself (`__shadowenv_data` current, GEM_HOME at the keg);
    # in a shell with none, `shadowenv exec` applies the project's lisps
    # before the child runs. A `"KEY" => nil` here is per-spawn hygiene
    # coming back — the discipline that failed four times (dev#180 nil'd
    # the wrapper's GEM_HOME leak; #274/#306 found that nil'ing it without
    # the marker made `shadowenv exec` a no-op and the child fell to brew's
    # prefix-wide gem dir; #333 saw CommandRunner repeat #274) before the
    # leak was fixed at its source. test/dev/spawn_seams_test.rb fails the
    # build on a nil'd key in either seam.
    class ShadowenvExec
      extend T::Sig

      # @param project_root [Pathname, String] root whose shadowenv the child runs under
      sig { params(project_root: T.any(String, Pathname)).void }
      def initialize(project_root:)
        @project_root = T.let(Pathname(project_root), Pathname)
      end

      # Run a command under the project's toolchain and capture its output.
      #
      # @param command [Array<String>] argv to run under `shadowenv exec --`
      # @param env [Hash{String => String, nil}] caller env for the child, layered over the inherited one
      # @return [Array(String, String, Process::Status)] stdout, stderr, exit status
      sig do
        params(
          command: String,
          env: T::Hash[String, T.nilable(String)],
        ).returns([String, String, Process::Status])
      end
      def capture3(*command, env: {})
        argv = ["shadowenv", "exec", "--", *command]
        T.unsafe(Open3).capture3(env, *argv, chdir: @project_root.to_s)
      end
    end
  end
end
