# typed: strict
# frozen_string_literal: true

require_relative "lifecycle/platform"
require_relative "lifecycle/config"
require_relative "lifecycle/target"
require_relative "lifecycle/build_pattern"
require_relative "lifecycle/build"
require_relative "lifecycle/git_state"
require_relative "lifecycle/build_id"
require_relative "lifecycle/manifest"
require_relative "lifecycle/artifact"
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
  # The verbs that act on these (`build`, `package`, `deploy`, `release`),
  # the Builder/Packager ports and the dispatch are the sibling milestones'
  # (dev#411–#415); this module is what they all speak.
  module Lifecycle
  end
end
