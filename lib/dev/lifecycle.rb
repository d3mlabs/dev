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
require_relative "lifecycle/publisher"
require_relative "lifecycle/publisher_spec"
require_relative "lifecycle/channel"
require_relative "lifecycle/script_publisher"
require_relative "lifecycle/ports"
require_relative "lifecycle/store"

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
  # A **channel** (Channel — a `deploy` child: the builds it accepts and
  # its protocol) ships artifacts through a third port, the **Publisher**
  # (ScriptPublisher — the child's `run:` once per archive, over the same
  # env contract). Ports resolves the declarations (BuilderSpec,
  # PackagerSpec, PublisherSpec) into them for a checkout.
  #
  # The verbs that act on these (`build`, `package`, `deploy`, `release`)
  # are LifecycleCommands in the CLI core (src/dev: the before → seam →
  # after template, Dispatch and DispatchResolver, dev#413), derived by the
  # sibling milestones (dev#414, dev#415); this module is what they all
  # speak.
  module Lifecycle
  end
end
