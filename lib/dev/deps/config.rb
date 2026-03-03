# frozen_string_literal: true

require_relative "dsl"

module Dev
  module Deps
    # Holds the parsed dependency configuration. Populated by Dev::Deps.define.
    # Three group concepts: app (runtime, linked with app), test (runtime, linked with test),
    # build (tooling, not in binaries). Build group supports nested env for env-specific brew.
    module Config
      def self.define(&block)
        dsl = DSL.new
        dsl.instance_eval(&block) if block
        @config = {
          "taps"                     => dsl.taps,
          "groups"                   => dsl.groups,
          "gems"                     => dsl.gems,
          "ruby_version_requirement" => dsl.ruby_version_requirement,
        }
      end

      def self.config
        @config || { "taps" => {}, "groups" => {}, "gems" => [] }
      end

      def self.taps
        config["taps"]
      end

      # Returns hash for a named group:
      # { "runtime" => [...], "brew" => [...], "env" => { "ci" => {...}, ... } }
      def self.group(name)
        config["groups"][name.to_s] || { "runtime" => [], "brew" => [], "env" => {} }
      end

      def self.gems
        config["gems"] || []
      end

      def self.ruby_version_requirement
        config["ruby_version_requirement"]
      end

      def self.local_tap_names
        taps.values
            .select { |t| t["url"].is_a?(String) && t["url"].start_with?("file://") }
            .map { |t| t["name"] }
      end
    end
  end
end
