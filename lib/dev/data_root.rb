# typed: strict
# frozen_string_literal: true

module Dev
  # Where dev's host-side artifacts (engines, dep caches, steam depots) live.
  #
  # On a plain machine that is `~/.dev`. On an agent host the register
  # bootstrap provisions a shared root (plans#26: anything both identities use
  # is system-visible, not per-user) and the data root points there — for the
  # human *and* the agent, so one engine tree serves both. Resolution is
  # derivable, never recorded (plans#26: inspected, no record file):
  # explicit `DEV_DATA_ROOT` env → the shared root when it exists → `~/.dev`.
  #
  # `expand` is the seam every dev-managed path takes: a configured path under
  # the literal `~/.dev` prefix (dev.yml install_dirs, volume specs) re-roots
  # onto the resolved data root; anything else expands normally. Mutable
  # per-user state (`~/.dev/state`) deliberately does not route through this —
  # it stays per-home.
  class DataRoot
    extend T::Sig

    # The shared-root location the agent bootstrap provisions. /Users/Shared
    # ships world-writable on macOS, so creation needs no sudo, and the path
    # reads as what it is: shared.
    SHARED_ROOT = "/Users/Shared/dev"

    # The per-user default, and the literal prefix `expand` re-roots.
    HOME_ROOT = "~/.dev"

    class << self
      extend T::Sig

      # The resolved data root (absolute).
      #
      # @param env [Hash{String => String}] process env (injectable for tests)
      # @param shared_root [String] shared-root location probed for presence
      # @return [String]
      sig { params(env: T::Hash[String, String], shared_root: String).returns(String) }
      def path(env: ENV.to_h, shared_root: SHARED_ROOT)
        explicit = env["DEV_DATA_ROOT"]
        return File.expand_path(explicit) if explicit && !explicit.empty?
        return shared_root if File.directory?(shared_root)

        File.expand_path(HOME_ROOT)
      end

      # Expand a configured path, re-rooting the `~/.dev` prefix onto the
      # resolved data root. Non-data-root paths (including `~/.dev*` siblings)
      # expand normally.
      #
      # @param path [String] a configured path (may use ~)
      # @param root [String] the data root (defaults to resolution)
      # @return [String] absolute path
      sig { params(path: String, root: String).returns(String) }
      def expand(path, root: self.path)
        return root if path == HOME_ROOT
        return File.join(root, path.delete_prefix("#{HOME_ROOT}/")) if path.start_with?("#{HOME_ROOT}/")

        File.expand_path(path)
      end
    end
  end
end
