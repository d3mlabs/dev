# typed: strict
# frozen_string_literal: true

require "pathname"
require "shellwords"
require "sorbet-runtime"
require "dev/build_container"
require "dev/lifecycle/snapshot"

module Dev
  # The build container's own checkout of the project (dev#421, ADR-0008
  # closed): the container is a remote that happens to be local, so it
  # works on a snapshot it fetched, never on the host's tree. One
  # workspace per checkout, under the container's data root —
  # `<data root>/workspaces/<project>-<workspace id>` — so it outlives the
  # container (a one-shot `docker run --rm`, a recreated service) and is
  # warm on the next snapshot: the fetch brings the delta, the reset moves
  # the tree, and what git ignores stays — `Intermediate/`, `.shadowenv.d/`
  # with the trust the container's own `dev deps install` wrote.
  #
  # The fetch is the container's, with the `gh` auth it holds (GH_TOKEN
  # from the host when it has one, its own login otherwise): a private
  # repo's snapshot branch is read as any job on a runner reads it. The
  # snapshot branch is named for the container's label (RUNNER), so a
  # `dev/build/container/*` branch on the forge says what it is, and `dev
  # cache gc` prunes the stale ones like any runner's.
  class ContainerWorkspace
    extend T::Sig

    # The runner label the snapshot branch is minted for: a flag's worth of
    # a label — a pool may be labelled `local`, and `host` is
    # `environment:`'s reserved word — fixed here.
    RUNNER = "container"

    # The data root subtree every workspace lives under.
    WORKSPACES_DIR = "workspaces"

    # gh's git credential helper, the way `gh auth setup-git` wires it:
    # the fetch authenticates as the container's gh does.
    GH_CREDENTIAL_HELPER = "!gh auth git-credential"

    # @return [Pathname] the workspace inside the container
    sig { returns(Pathname) }
    attr_reader :path

    # @param project_root [Pathname] the host's checkout the workspace mirrors
    # @param data_root [String] the container's data root path (BuildContainer#data_root_mount)
    sig { params(project_root: Pathname, data_root: String).void }
    def initialize(project_root:, data_root:)
      name = "#{File.basename(BuildContainer.workspace_path(project_root))}-#{BuildContainer.workspace_id(project_root)}"
      @path = T.let(Pathname(data_root) / WORKSPACES_DIR / name, Pathname)
    end

    # The shell program a container runs for one invocation: bring the
    # workspace to the snapshot, then become the command there. `sh -c`
    # material, every value quoted.
    #
    # @param snapshot [Lifecycle::Snapshot] the pushed tree
    # @param repo [String] the forge's `owner/repo`, where the snapshot branch is
    # @param argv [Array<String>] the command to exec in the workspace
    # @return [String]
    sig { params(snapshot: Lifecycle::Snapshot, repo: String, argv: T::Array[String]).returns(String) }
    def script(snapshot:, repo:, argv:)
      workspace = Shellwords.escape(@path.to_s)
      <<~SH
        set -e
        mkdir -p #{workspace}
        cd #{workspace}
        [ -d .git ] || git -c advice.defaultBranchName=false init -q
        git -c credential.helper= -c #{Shellwords.escape("credential.helper=#{GH_CREDENTIAL_HELPER}")} \\
          fetch -q --no-tags #{Shellwords.escape(fetch_url(repo))} #{Shellwords.escape(snapshot.branch.ref)}
        git reset -q --hard #{Shellwords.escape(snapshot.sha)}
        git clean -qfd
        exec #{argv.shelljoin}
      SH
    end

    private

    # @param repo [String] `owner/repo`
    # @return [String] the HTTPS clone URL, the one gh's helper authenticates
    sig { params(repo: String).returns(String) }
    def fetch_url(repo) = "https://github.com/#{repo}.git"
  end
end
