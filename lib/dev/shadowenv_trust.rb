# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  # Trust for a project's `.shadowenv.d`, established for the user running
  # dev — `shadowenv trust` in the project root.
  #
  # shadowenv's trust is a signature over the directory made with the
  # caller's key (`~/.config/shadowenv/trust-key-v2`), recorded as a
  # `.trust-<key>` file beside the lisps. It is a property of (directory,
  # user), not of what the files say — so a user who has never trusted a
  # directory cannot run its shadowenv however current its activation files
  # are. That user is real: the `builder` of a freshly created build
  # container, whose home (and key) is new while the bind-mounted
  # `.shadowenv.d` already carries the `_container` lisps a previous
  # container wrote. The activation writers trust only after a write they
  # made, so with nothing to rewrite nobody trusted, and the first
  # `shadowenv exec` of the install — bundler's — was refused: `directory
  # contains untrusted shadowenv program`. Provisioning therefore trusts up
  # front, unconditionally: making the project's shadowenv runnable for
  # this user is part of what installing means.
  #
  # A project with no `.shadowenv.d` yet is left alone: `shadowenv trust`
  # has nothing to sign there ("no shadowenv found"), and the first writer
  # creates and trusts it.
  class ShadowenvTrust
    extend T::Sig

    # `shadowenv trust` exited nonzero, or shadowenv is not on PATH.
    class TrustFailedError < StandardError; end

    # Trust the project's `.shadowenv.d` for the running user.
    #
    # @param project_root [Pathname, String] the project root (`.shadowenv.d` lives there)
    # @return [Boolean] true when trust ran, false when there was nothing to trust yet
    # @raise [TrustFailedError] when shadowenv refuses or is missing
    sig { params(project_root: T.any(Pathname, String)).returns(T::Boolean) }
    def ensure!(project_root:)
      root = Pathname(project_root)
      return false unless (root / ".shadowenv.d").directory?

      _out, err, status = Open3.capture3("shadowenv", "trust", chdir: root.to_s)
      raise TrustFailedError, "shadowenv trust failed in #{root}: #{err.strip}" unless status.success?

      true
    rescue Errno::ENOENT
      raise TrustFailedError, "shadowenv trust failed in #{root}: shadowenv not found on PATH"
    end
  end
end
