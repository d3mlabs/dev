# typed: strict
# frozen_string_literal: true

require "dev/learnings/layout"
require "dev/learnings/scaffolder"
require "dev/learnings/cache"
require "dev/learnings/invariants_renderer"
require "dev/learnings/synchronizer"
require "dev/learnings/accessor"

module Dev
  # The learnings read path: a machine cache of the org knowledge repo, org
  # skills linked into ~/.cursor/skills, one machine-side render of the
  # invariants index, and a per-project symlink at that render. See
  # `dev learnings` (Dev::Learnings::Accessor) for the command surface;
  # the passive path rides dev's hook points via Synchronizer#sync.
  module Learnings
  end
end
