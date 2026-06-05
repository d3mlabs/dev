# frozen_string_literal: true

require_relative "deps/config"
require_relative "deps/cli_ui"
require_relative "deps/lockfile"
require_relative "deps/fetcher"
require_relative "deps/deps_orchestrator"

module Dev
  module Deps
    def self.define(&block)
      Config.define(&block)
    end
  end
end
