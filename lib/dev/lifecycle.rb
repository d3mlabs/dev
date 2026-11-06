# typed: strict
# frozen_string_literal: true

require_relative "lifecycle/platform"
require_relative "lifecycle/config"
require_relative "lifecycle/shell"
require_relative "lifecycle/byte_size"
require_relative "lifecycle/packed_archive"
require_relative "lifecycle/builder"
require_relative "lifecycle/packager"
require_relative "lifecycle/archive"
require_relative "lifecycle/builder_spec"
require_relative "lifecycle/packager_spec"
require_relative "lifecycle/target_environment"
require_relative "lifecycle/target"
require_relative "lifecycle/build_pattern"
require_relative "lifecycle/build"
require_relative "lifecycle/release_builds"
require_relative "lifecycle/git_state"
require_relative "lifecycle/build_id"
require_relative "lifecycle/project_version"
require_relative "lifecycle/manifest"
require_relative "lifecycle/artifact"
require_relative "lifecycle/script_env"
require_relative "lifecycle/script_builder"
require_relative "lifecycle/script_packager"
require_relative "lifecycle/as_is_packager"
require_relative "lifecycle/none_packager"
require_relative "lifecycle/track"
require_relative "lifecycle/receipt"
require_relative "lifecycle/publisher"
require_relative "lifecycle/publisher_spec"
require_relative "lifecycle/channel"
require_relative "lifecycle/script_publisher"
require_relative "lifecycle/ports"
require_relative "lifecycle/store"
require_relative "lifecycle/release_tag"
require_relative "lifecycle/deployment_state"
require_relative "lifecycle/deployment_record"
require_relative "lifecycle/deployment"
require_relative "lifecycle/gh"
require_relative "lifecycle/github_deployments"
require_relative "lifecycle/github_releases"
require_relative "lifecycle/git"
require_relative "lifecycle/release_cut"
require_relative "lifecycle/release_assets"
require_relative "lifecycle/snapshot_branch"
require_relative "lifecycle/snapshot"
require_relative "lifecycle/snapshot_commit"
require_relative "lifecycle/snapshot_branches"
require_relative "lifecycle/workflow_triggers"
require_relative "lifecycle/snapshot_sync"

module Dev
  # The vocabulary and the store of the build lifecycle (dev#192): a project
  # declares **targets** (dev.yml `targets:`); dev derives their **builds**
  # (target × platform × config, one fully-qualified name each, the grammar
  # in BuildPattern); `package` turns a build into an **artifact** (an
  # archive plus `build-id.json`) in the Store under the data root; a
  # **release** is the tag plus the archives on the forge, described by
  # `release.json`. Platform and Config are the two closed id sets every
  # surface spells the axes in.
  #
  # Between dev and the toolchain sit two ports, one per verb: the
  # **Builder** makes a build's install (ScriptBuilder — the target's
  # `build:` line over the ScriptEnv contract), the **Packager** makes the
  # archive (Archive — dev's own zip or split tar, the default;
  # AsIsPackager; NonePackager; ScriptPackager for a `package:` line).
  # A **channel** (Channel — a `deploy` child, or one the lock contributes:
  # the builds it accepts and its protocol) ships artifacts through a
  # third port, the **Publisher** (ScriptPublisher — the child's `run:`
  # once per archive, over the same env contract; an integration's
  # publisher, a black box over the read-only archives with the channel's
  # scratch in the Store), on the **Track** the source decides (testing
  # from the store, live for a release), and hands back a Receipt. Ports
  # resolves the declarations (BuilderSpec, PackagerSpec, PublisherSpec)
  # into them for a checkout. What a deploy leaves behind is not in the
  # store: GithubDeployments records each as a GitHub Deployment
  # (DeploymentRecord — channel, ref, track, builds, state, the receipt —
  # read back as a Deployment), through Gh, the lifecycle's one gh
  # boundary; ReleaseTag is the ref a release's deploy is recorded against.
  #
  # A **release** (dev#424) is the cut and nothing more: ReleaseBuilds is
  # what `release:` says one contains; ReleaseCut is its git half (clean
  # tree, the bump commit, the tag, the push — resumable); ReleaseAssets
  # names each artifact's archive `<build>-<version>.<ext>` for the
  # upload; GithubReleases is the release archive on the forge, where the
  # assets and `release.json` (Manifest::Release) land. Nothing is
  # deployed by it — distribution is `deploy --release` per channel.
  #
  # The verbs that act on these (`build`, `package`, `deploy`, `release`)
  # are LifecycleCommands in the CLI core (src/dev: the before → seam →
  # after template, Dispatch and DispatchResolver, dev#413), derived by the
  # sibling milestones (dev#414, dev#415, dev#424); this module is what
  # they all speak.
  #
  # The **sync step** of the remote dispatch (K7) is here too: SnapshotSync
  # commits the working tree through a temporary index (SnapshotCommit),
  # pushes it to a SnapshotBranch (`dev/build/<runner>/<id>`) in the
  # `origin` namespace SnapshotBranches owns — and prunes by age for
  # `dev cache gc` — after WorkflowTriggers has checked that no project
  # workflow would run on the push; Git is the one CLI boundary they share.
  module Lifecycle
  end
end
