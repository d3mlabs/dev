# typed: strict
# frozen_string_literal: true

require_relative "gh_integration"
require_relative "steam_integration"
require_relative "wwise_integration"

module Dev
  module Deps
    # The integrations that publish version-keyed trees to the store, by lock
    # section. Each places its trees itself (`.tree_key`); this is the one
    # list of who does, for the parts of dev that walk a lock looking for
    # trees without installing them (CacheGc).
    TREE_INTEGRATIONS = T.let(
      { gh: GhIntegration, steam: SteamIntegration, wwise: WwiseIntegration }.freeze,
      T::Hash[Symbol, T.class_of(Integration)],
    )
  end
end
