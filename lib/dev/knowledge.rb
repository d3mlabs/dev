# frozen_string_literal: true

require "dev/knowledge/cache"
require "dev/knowledge/invariants_renderer"
require "dev/knowledge/synchronizer"
require "dev/knowledge/accessor"

module Dev
  # Org knowledge distribution: a TTL-refreshed machine cache of the org
  # knowledge repo, org skills linked into ~/.cursor/skills, and the
  # invariants index rendered into each project dev touches. See
  # `dev knowledge` (Dev::Knowledge::Accessor) for the command surface;
  # the passive path rides dev's hook points via Synchronizer#sync.
  module Knowledge
  end
end
