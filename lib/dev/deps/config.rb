# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "dsl"
require_relative "tap"

module Dev
  module Deps
    # Parsed dependency configuration. Returned by Dev::Deps.define.
    class Config
      extend T::Sig

      # @return [Array<Tap>] declared Homebrew taps
      sig { returns(T::Array[Tap]) }
      attr_reader :taps

      # @return [Array<ScopedDeclaration>] all declared dependencies
      sig { returns(T::Array[ScopedDeclaration]) }
      attr_reader :declarations

      # @return [Array<ScopedDeclaration>] the ungrouped declarations — what
      #   this manifest exports when read as a library (ADR-0011's export
      #   rule: grouped declarations are private, and the toolchain
      #   directives — ruby, python — and env scoping never propagate)
      sig { returns(T::Array[ScopedDeclaration]) }
      attr_reader :exports

      # @return [String, nil] required Ruby version
      sig { returns(T.nilable(String)) }
      attr_reader :ruby_version_requirement

      # @return [String, nil] Lua version for LuaRocks
      sig { returns(T.nilable(String)) }
      attr_reader :lua_version

      # @return [String, nil] Python minor version for the pip venv
      sig { returns(T.nilable(String)) }
      attr_reader :python_version

      # @return [Hash{Symbol => Class, String}] custom integration registrations
      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :registered_integrations

      # @param taps [Array<Tap>] declared Homebrew taps
      # @param declarations [Array<ScopedDeclaration>] all declared dependencies
      #   (gems are :bundler declarations, brew formulae are :brew declarations, etc.)
      # @param exports [Array<ScopedDeclaration>] the ungrouped subset of
      #   declarations
      # @param ruby_version_requirement [String, nil] required Ruby version
      # @param lua_version [String, nil] Lua version for LuaRocks
      # @param python_version [String, nil] Python minor version for the pip venv
      # @param registered_integrations [Hash{Symbol => Class}] custom integration registrations
      sig do
        params(
          taps: T::Array[Tap],
          declarations: T::Array[ScopedDeclaration],
          exports: T::Array[ScopedDeclaration],
          ruby_version_requirement: T.nilable(String),
          lua_version: T.nilable(String),
          python_version: T.nilable(String),
          registered_integrations: T::Hash[Symbol, T.untyped],
        ).void
      end
      def initialize(taps:, declarations:, exports:, ruby_version_requirement:,
                     lua_version:, python_version:, registered_integrations:)
        @taps = taps
        @declarations = declarations
        @exports = exports
        @ruby_version_requirement = ruby_version_requirement
        @lua_version = lua_version
        @python_version = python_version
        @registered_integrations = registered_integrations
      end

      class << self
        extend T::Sig

        # Evaluate a DSL block and return a Config instance.
        #
        # @param block [Proc] DSL block evaluated in DSL context
        # @return [Config]
        sig { params(block: T.nilable(T.proc.bind(DSL).void)).returns(Config) }
        def define(&block)
          dsl = DSL.new
          dsl.instance_eval(&block) if block

          taps = dsl.taps.map do |_name, raw|
            Tap.new(name: raw["name"], url: raw["url"])
          end

          new(
            taps:,
            declarations: dsl.declarations,
            exports: dsl.exports,
            ruby_version_requirement: dsl.ruby_version_requirement,
            lua_version: dsl.lua_version_value,
            python_version: dsl.python_version_value,
            registered_integrations: dsl.registered_integrations,
          )
        end
      end
    end
  end
end
