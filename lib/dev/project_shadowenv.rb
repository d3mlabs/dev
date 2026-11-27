# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "container_context"

module Dev
  # A project's shadowenv on one side of the build container: the directory
  # shadowenv searches from, and the `.shadowenv.d` it finds there.
  #
  # The checkout is bind-mounted into the build container as one tree, and
  # an activation names one build host's prefixes (`/opt/homebrew` against
  # Linuxbrew's), so each side needs a `.shadowenv.d` of its own. The
  # host's is the conventional one at the project root, where the shell
  # hook finds it by cwd. The container's is nested under
  # `.shadowenv.d-container/` in the same checkout, and every shadowenv
  # invocation inside is pointed there: `shadowenv exec --dir <search
  # root>`, `shadowenv trust` run in it. Nothing is mounted over anything,
  # so the host deleting either directory under a running container
  # (`actions/checkout`'s `git clean -ffdx`, a developer's) costs the next
  # install a rewrite, exactly as it does on the host (dev#723, dev#732).
  #
  # Writers (ShadowenvFile and the older per-tool modules) place lisps in
  # `dir`; the two spawn seams (Deps::ShadowenvExec, Cli::CommandRunner)
  # and ShadowenvTrust point shadowenv at `search_root`. ShadowenvTrust
  # also makes `dir` before the first spawn: shadowenv searches upward from
  # `search_root`, and a missing nested directory would hand the container
  # the host's lisps.
  class ProjectShadowenv
    extend T::Sig

    # The directory shadowenv reads, on either side.
    DIR = ".shadowenv.d"
    # Where the container's shadowenv searches from: a dev-owned, ignored
    # sibling of the host's directory in the checkout, keyed by side as the
    # venv link is (ShadowenvPython::CONTAINER_VENV_DIR).
    CONTAINER_SEARCH_ROOT = ".shadowenv.d-container"
    # Both sides' directories as the repo-relative .gitignore lines covering
    # them — collected by Dev::Footprint. A lisp names one machine's
    # prefixes; neither directory ever commits.
    GITIGNORE_FOOTPRINT = T.let(["#{DIR}/", "#{CONTAINER_SEARCH_ROOT}/"].freeze, T::Array[String])

    # @param project_root [Pathname, String] the checkout
    # @param inside [Boolean] whether this dev runs inside the build container
    sig { params(project_root: T.any(Pathname, String), inside: T::Boolean).void }
    def initialize(project_root, inside: ContainerContext.inside?)
      @project_root = T.let(Pathname(project_root), Pathname)
      @inside = inside
    end

    # The directory shadowenv searches from for this side's `.shadowenv.d`:
    # `shadowenv exec --dir`, `shadowenv trust`'s working directory.
    #
    # @return [Pathname] the project root on the host, `.shadowenv.d-container/` inside
    sig { returns(Pathname) }
    def search_root
      @inside ? @project_root / CONTAINER_SEARCH_ROOT : @project_root
    end

    # This side's `.shadowenv.d`, where the activation lisps go.
    #
    # @return [Pathname]
    sig { returns(Pathname) }
    def dir
      search_root / DIR
    end
  end
end
