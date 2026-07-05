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

    # Detect the current environment (ci vs dev) from the CI variable alone.
    #
    # Deliberately NOT platform-based: a Linux workstation is "dev" and a Mac
    # CI runner is "ci". The one caller that needed the old Linux-implies-CI
    # clause (bin/install-build-deps.rb, which runs inside docker builds where
    # no CI variable exists) now declares env: "ci" explicitly instead of
    # detecting it — fix by declaration, not detection.
    #
    # @return [String] "ci" or "dev"
    def self.detect_env
      ENV["CI"].to_s =~ /\A(true|1)\z/i ? "ci" : "dev"
    end

    # Detect the host OS for host-gated dependency filtering (the `host:`
    # declaration axis). Matches the symbols the DSL accepts (:darwin, :linux).
    #
    # @return [String] "darwin", "linux", or "windows"
    def self.detect_host
      case RUBY_PLATFORM
      when /darwin/ then "darwin"
      when /linux/ then "linux"
      else "windows"
      end
    end
  end
end
