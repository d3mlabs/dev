# frozen_string_literal: true

require_relative "deps/config"
require_relative "deps/brew"
require_relative "deps/taps"
require_relative "deps/lockfile"
require_relative "deps/fetcher"

module Dev
  module Deps
    def self.define(&block)
      Config.define(&block)
    end
  end
end
