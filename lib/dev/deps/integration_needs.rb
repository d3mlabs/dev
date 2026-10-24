# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dev/deps"
require_relative "integration"
require_relative "scoped_declaration"

module Dev
  module Deps
    # Reads each integration's own dependencies.rb as a library and builds
    # the needs table the Resolver walks: integration symbol → the
    # declarations that manifest exports (ADR-0011).
    #
    # Library mode is the export rule applied: only ungrouped declarations
    # export (grouped ones are the library's private business and env never
    # propagates — both facts of Config#exports), the toolchain directives
    # (ruby, python) are not read, and the library's own lock, if any, is
    # never consulted — a library declares, the project locks. The one check
    # with teeth is that an integration may not need a pin of its own type:
    # the installer orders integration batches by the needs graph, and such
    # a need would be a self-edge it could only refuse.
    class IntegrationNeeds
      extend T::Sig

      # An integration's manifest exports a declaration of the integration's
      # own type.
      class SelfNeedError < StandardError; end

      # The needs table for these integrations. Integrations without a
      # manifest are absent: they need no tooling of their own.
      #
      # @param integrations [Hash{Symbol => Class}] integration symbol → the
      #   Integration class that installs it
      # @return [Hash{Symbol => Array<ScopedDeclaration>}] symbol → the
      #   manifest's exports, for integrations that carry a manifest
      # @raise [SelfNeedError] if a manifest exports its own integration type
      # @raise [UndefinedManifestError] if a manifest never calls Dev::Deps.define
      sig do
        params(
          integrations: T::Hash[Symbol, T.class_of(Integration)],
        ).returns(T::Hash[Symbol, T::Array[ScopedDeclaration]])
      end
      def table(integrations)
        integrations.each_with_object({}) do |(symbol, klass), table|
          manifest = klass.manifest_path
          next unless manifest

          table[symbol] = exports_of(manifest, symbol)
        end
      end

      private

      # @param manifest [Pathname] the integration's dependencies.rb
      # @param symbol [Symbol] the integration the manifest belongs to
      # @return [Array<ScopedDeclaration>] the manifest's exports
      # @raise [SelfNeedError] if any export is of the integration's own type
      sig { params(manifest: Pathname, symbol: Symbol).returns(T::Array[ScopedDeclaration]) }
      def exports_of(manifest, symbol)
        exports = Dev::Deps.evaluate(manifest).exports
        self_needs = exports.select { |need| need.integration == symbol }
        if self_needs.any?
          raise SelfNeedError,
            "#{manifest} needs #{self_needs.map(&:name).join(", ")} of its own integration (#{symbol}) — " \
              "an integration's needs are pins of other integrations, installed before it"
        end

        exports
      end
    end
  end
end
