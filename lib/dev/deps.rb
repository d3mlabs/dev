# frozen_string_literal: true

require_relative "deps/config"
require_relative "deps/cli_ui"
require_relative "deps/lockfile"
require_relative "deps/fetcher"
require_relative "deps/dependency_installer"

module Dev
  module Deps
    @last_config = nil

    def self.define(&block)
      @last_config = Config.define(&block)
    end

    # The most recently defined config (from the last call to .define).
    # Useful for retrieving the config after loading a dependencies.rb file.
    #
    # @return [Config, nil]
    def self.last_config
      @last_config
    end

    # Detect the current environment (ci vs dev).
    #
    # CI-like environments (CI=true, Linux) → "ci"; everything else → "dev".
    #
    # @return [String] "ci" or "dev"
    def self.detect_env
      ci_like = ENV["CI"].to_s =~ /\A(true|1)\z/i
      linux = RUBY_PLATFORM.to_s.include?("linux")
      (ci_like || linux) ? "ci" : "dev"
    end
  end
end
