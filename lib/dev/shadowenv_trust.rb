# typed: strict
# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require_relative "project_shadowenv"

module Dev
  # Trust for a project's `.shadowenv.d`, established for the user running
  # dev — `shadowenv trust` where this side's shadowenv is searched from
  # (ProjectShadowenv#search_root).
  #
  # shadowenv's trust is a signature over the directory made with the
  # caller's key (`~/.config/shadowenv/trust-key-v2`), recorded as a
  # `.trust-<key>` file beside the lisps. It is a property of (directory,
  # user), not of what the files say — so a user who has never trusted a
  # directory cannot run its shadowenv however current its activation files
  # are. That user is real: the `builder` of a freshly created build
  # container, whose home (and key) is new while the container's shadowenv
  # directory in the checkout already carries the lisps a previous
  # container wrote. The activation writers trust
  # only after a write they made, so with nothing to rewrite nobody
  # trusted, and the first
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

    # Trust this side's `.shadowenv.d` for the running user, making it
    # first when it does not exist yet. An empty, trusted directory is the
    # "nothing activated yet" state; a missing one is not — shadowenv
    # searches upward from `--dir`, and the nearest `.shadowenv.d` above
    # the container's search root is the host's, whose lisps name the
    # host's prefixes. The host's directory sits at the project root, so
    # the same rule there keeps a parent directory's shadowenv out too.
    #
    # @param project_root [Pathname, String] the project root (this side's shadowenv is under it)
    # @return [Boolean] true — trust ran
    # @raise [TrustFailedError] when shadowenv refuses or is missing
    sig { params(project_root: T.any(Pathname, String)).returns(T::Boolean) }
    def ensure!(project_root:)
      shadowenv = ProjectShadowenv.new(project_root)
      FileUtils.mkdir_p(shadowenv.dir)

      root = shadowenv.search_root
      _out, err, status = Open3.capture3("shadowenv", "trust", chdir: root.to_s)
      raise TrustFailedError, "shadowenv trust failed in #{root}: #{err.strip}" unless status.success?

      true
    rescue Errno::ENOENT
      raise TrustFailedError, "shadowenv trust failed in #{root}: shadowenv not found on PATH"
    end
  end
end
