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
    # Env hygiene is not this seam's job. A caller's hostile activation
    # (a harness's `bundle exec`, a sandbox's BUNDLE_PATH) is stripped once,
    # at bin/dev's entrypoint, before any Ruby exists; by the time this
    # class runs those keys are gone, and a second list here is how two
    # spawn sites drift apart (dev#306 fixed one and the other regressed
    # with the identical failure). CommandRunner's direct run — the other
    # `shadowenv exec` spawn — derives what it clears from this constant,
    # never keeps its own.
    #
    # What remains, transitionally, is the one contamination dev inflicts
    # on itself: the dev-core wrapper still exports GEM_HOME=libexec into
    # dev's process (an installed dev no longer needs it — bin/dev selects
    # its vendored gems in-process — but the wrapper is the tap's to
    # change). A child inheriting it would install a project's gems into
    # dev-core's Cellar (dev#180), so it is nil'd. Nil'ing it alone is the
    # dev#274 failure: `shadowenv exec` applies the project's lisps only
    # when the `__shadowenv_data` marker says they are not already active,
    # so in a project shell it would hand the child an env with no GEM_HOME
    # at all, and a brew Ruby then falls back to the prefix-wide gem dir
    # shared by every brew Ruby, where another Ruby's native extensions
    # live. The marker goes with the activation it describes, and
    # `shadowenv exec` re-applies the lisps from the scrubbed base. When the
    # wrapper stops exporting GEM_HOME, both keys go and this seam clears
    # nothing.
    class ShadowenvExec
      extend T::Sig

      # The transitional pair (see the class comment): dev's own GEM_HOME
      # export and the active-project marker that must travel with it.
      # test/dev/deps/shadowenv_exec_test.rb pins the exact set.
      RUBY_ENV_SCRUB = T.let(
        {
          "GEM_HOME" => nil,
          "__shadowenv_data" => nil,
        }.freeze,
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
