# frozen_string_literal: true

require_relative "dsl"
require_relative "tap"

module Dev
  module Deps
    # Parsed dependency configuration. Returned by Dev::Deps.define.
    class Config
      attr_reader :taps, :groups, :declarations, :ruby_version_requirement,
                  :lua_version, :registered_integrations

      # @param taps [Array<Tap>] declared Homebrew taps
      # @param groups [Hash] group name → { "brew" => [...], "env" => {...} }
      # @param declarations [Array<DependencyDeclaration>] all declared dependencies
      #   (gems are :bundler declarations, brew formulae are :brew declarations, etc.)
      # @param ruby_version_requirement [String, nil] required Ruby version
      # @param lua_version [String, nil] Lua version for LuaRocks
      # @param registered_integrations [Hash{Symbol => Class}] custom integration registrations
      def initialize(taps:, groups:, declarations:, ruby_version_requirement:,
                     lua_version:, registered_integrations:)
        @taps = taps
        @groups = groups
        @declarations = declarations
        @ruby_version_requirement = ruby_version_requirement
        @lua_version = lua_version
        @registered_integrations = registered_integrations
      end

      # Return the config for a named group, with safe defaults for missing groups.
      #
      # @param name [String, Symbol] group name
      # @return [Hash]
      def group(name)
        @groups[name.to_s] || { "brew" => [], "env" => {} }
      end

      # Evaluate a DSL block and return a Config instance.
      #
      # @param block [Proc] DSL block evaluated in DSL context
      # @return [Config]
      def self.define(&block)
        dsl = DSL.new
        dsl.instance_eval(&block) if block

        taps = dsl.taps.map do |_name, raw|
          Tap.new(name: raw["name"], url: raw["url"])
        end

        new(
          taps:,
          groups: dsl.groups,
          declarations: dsl.declarations,
          ruby_version_requirement: dsl.ruby_version_requirement,
          lua_version: dsl.lua_version_value,
          registered_integrations: dsl.registered_integrations,
        )
      end
    end
  end
end
