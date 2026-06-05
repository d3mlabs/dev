# frozen_string_literal: true

require_relative "dsl"

module Dev
  module Deps
    # Parsed dependency configuration. Returned by Dev::Deps.define.
    class Config
      attr_reader :taps, :groups, :gems, :ruby_version_requirement,
                  :lua_version, :registered_integrations

      # @param taps [Hash] declared Homebrew taps
      # @param groups [Hash] group name → { "runtime" => [...], "brew" => [...], "env" => {...} }
      # @param gems [Array<Hash>] declared Ruby gems
      # @param ruby_version_requirement [String, nil] required Ruby version
      # @param lua_version [String, nil] Lua version for LuaRocks
      # @param registered_integrations [Hash{Symbol => Class}] custom integration registrations
      def initialize(taps:, groups:, gems:, ruby_version_requirement:, lua_version:, registered_integrations:)
        @taps = taps
        @groups = groups
        @gems = gems
        @ruby_version_requirement = ruby_version_requirement
        @lua_version = lua_version
        @registered_integrations = registered_integrations
      end

      # Return the config for a named group, with safe defaults for missing groups.
      #
      # @param name [String, Symbol] group name
      # @return [Hash]
      def group(name)
        @groups[name.to_s] || { "runtime" => [], "brew" => [], "env" => {} }
      end

      # Return tap names that use file:// URLs (local taps).
      #
      # @return [Array<String>]
      def local_tap_names
        taps.values
            .select { |t| t["url"].is_a?(String) && t["url"].start_with?("file://") }
            .map { |t| t["name"] }
      end

      # Evaluate a DSL block and return a Config instance.
      #
      # @param block [Proc] DSL block evaluated in DSL context
      # @return [Config]
      def self.define(&block)
        dsl = DSL.new
        dsl.instance_eval(&block) if block
        new(
          taps: dsl.taps,
          groups: dsl.groups,
          gems: dsl.gems,
          ruby_version_requirement: dsl.ruby_version_requirement,
          lua_version: dsl.lua_version_value,
          registered_integrations: dsl.registered_integrations,
        )
      end
    end
  end
end
