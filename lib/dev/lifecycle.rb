# typed: strict
# frozen_string_literal: true

require_relative "lifecycle/platform"
require_relative "lifecycle/config"
require_relative "lifecycle/shell"
require_relative "lifecycle/byte_size"
require_relative "lifecycle/part_list"
require_relative "lifecycle/packed_archive"
require_relative "lifecycle/builder"
require_relative "lifecycle/packager"
require_relative "lifecycle/archive"
require_relative "lifecycle/unpacker"
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
require_relative "lifecycle/release_tag"
require_relative "lifecycle/shipment"
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
require_relative "lifecycle/deployment_state"
require_relative "lifecycle/deployment_record"
require_relative "lifecycle/deployment"
require_relative "lifecycle/gh"
require_relative "lifecycle/github_deployments"
require_relative "lifecycle/github_releases"
require_relative "lifecycle/git"
require_relative "lifecycle/release_cut"
require_relative "lifecycle/release_assets"
require_relative "lifecycle/release_archives"
require_relative "lifecycle/snapshot_branch"
require_relative "lifecycle/snapshot"
require_relative "lifecycle/snapshot_commit"
require_relative "lifecycle/snapshot_branches"
require_relative "lifecycle/workflow_triggers"
require_relative "lifecycle/snapshot_sync"
require_relative "lifecycle/artifact_fetch"
require_relative "lifecycle/verb_invocation"
require_relative "lifecycle/lifecycle_workflow"
require_relative "lifecycle/workflow_run"
require_relative "lifecycle/workflow_runs"
require_relative "lifecycle/step_outputs"

module Dev
  # The build lifecycle: a project declares targets in dev.yml, dev derives
  # their builds (target × platform × config), `package` turns a build into
  # an artifact in the Store, `deploy` ships artifacts to a channel, and
  # `release` tags and attaches archives to a GitHub release.
  #
  # Three ports separate dev from the toolchain and the destination: a
  # Builder makes a build's install, a Packager makes its archive, a
  # Publisher ships the archives a deploy selected. Ports resolves a
  # target's and a channel's declarations into them.
  #
  # Deploys are recorded as GitHub Deployments (GithubDeployments); a
  # release lives on the forge (GithubReleases) and is read back for
  # `deploy --release` by ReleaseArchives.
  #
  # A verb that leaves the machine goes through SnapshotSync, which pushes
  # the working tree to a snapshot branch, runs the dispatch and deletes the
  # branch. The operator's view is docs/lifecycle.md; the class map is
  # docs/lifecycle-architecture.md.
  module Lifecycle
  end
end
