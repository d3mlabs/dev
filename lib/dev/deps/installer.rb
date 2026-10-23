# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "dependency"
require_relative "integration"

module Dev
  module Deps
    # Reads locked dependencies and dispatches to integrations.
    #
    # Cross-cutting install concerns (env filtering, install ordering) live
    # here — not in Integration or Lockfile.
    class Installer
      extend T::Sig

      # The install order has a cycle: some integration's needs are, directly
      # or through other integrations, pins of its own batch, so no batch
      # can go first. Refused rather than guessed — an integration's needs
      # must be pins of other integrations.
      class DependencyCycleError < StandardError; end

      # Aggregate of every failure across the whole install run, raised after
      # all integrations were attempted. Entries follow install order
      # (prerequisites first), so root causes appear before derivative
      # failures. Raising keeps the caller contract unchanged: a failed run
      # exits non-zero and never writes the installed stamp.
      class InstallFailedError < StandardError
        extend T::Sig

        # @return [Array<String>] one human-readable line per failure
        sig { returns(T::Array[String]) }
        attr_reader :entries

        # @param entries [Array<String>]
        sig { params(entries: T::Array[String]).void }
        def initialize(entries)
          @entries = entries
          super("#{entries.size} dependency install failure(s) — " \
            "installs are idempotent, fix the causes and rerun:\n" \
            "#{entries.map { |entry| "  #{entry}" }.join("\n")}")
        end
      end

      # @param lockfile [Lockfile] lockfile reader
      # @param integrations [Hash{Symbol => Integration}] integration type → integration
      sig { params(lockfile: Lockfile, integrations: T::Hash[Symbol, T.untyped]).void }
      def initialize(lockfile:, integrations:)
        @lockfile = lockfile
        @integrations = integrations
      end

      # Read lockfiles and dispatch to integrations, in the order the lock's
      # graph dictates.
      #
      # Install order is a topological sort over integration batches. The
      # edges are the lock's own: a pin recorded as `needed_by` an
      # integration (the tooling that integration's manifest exports — xcodes
      # for xcode, wwise-cli for wwise) installs before that integration's
      # batch; and the host prerequisite (brew, through which every such tool
      # arrives) installs before everything. Groups play no part: they are
      # purpose, selected by --group/--except, and nothing installs first
      # because of its group name (ADR-0011). A cycle is refused.
      #
      # Selection (env, host, groups, except) is {select}'s one pure filter.
      # Filtering happens here — at install, never at resolve — so the lockfile
      # stays the single source of truth for every environment, host and
      # install site.
      #
      # @param env [String, nil] environment name for filtering (nil = no filtering)
      # @param host [String, nil] host OS name for filtering (nil = no filtering)
      # @param groups [Array<Symbol>, nil] install only these groups (nil = all)
      # @param except [Array<Symbol>] never install these groups
      # @param integration_types [Array<Symbol>, nil] install only deps of
      #   these integrations, by lock key (e.g. [:brew]); nil = all
      # @return [void]
      # @raise [DependencyCycleError] if the selected pins' needs form a cycle
      # @raise [InstallFailedError] if any integration reported failures; every
      #   integration was still attempted (failure isolation)
      sig do
        params(
          env: T.nilable(String),
          host: T.nilable(String),
          groups: T.nilable(T::Array[Symbol]),
          except: T::Array[Symbol],
          integration_types: T.nilable(T::Array[Symbol]),
        ).void
      end
      def install(env: nil, host: nil, groups: nil, except: [], integration_types: nil)
        selected = self.class.select(@lockfile.read, env:, host:, groups:, except:, integration_types:)

        failures = ordered_batches(selected).flat_map { |integration, deps| dispatch(integration, deps) }
        raise InstallFailedError, failures if failures.any?
      end

      class << self
        extend T::Sig

        # The deps an install with these parameters would attempt — the one
        # implementation of selection, shared by {#install} and by callers
        # that must know the selection before installing (the builtin decides
        # whether the project Ruby is needed from it).
        #
        # env/host: deps without the metadata always pass; deps with it pass
        # only on a match (the Mac editor never downloads on Linux CI, the
        # Linux engine never downloads on Macs). groups: nil means every
        # group. except: wins over groups. integration_types: keeps only deps
        # of the named integrations (a group can mix an image toolchain with
        # a host-installed artifact; an image bootstrap wants the former).
        #
        # @param deps [Array<Dependency>] every locked dep
        # @param env [String, nil] environment name ("dev" / "ci")
        # @param host [String, nil] detected host OS ("darwin" / "linux")
        # @param groups [Array<Symbol>, nil] groups to keep (nil = all)
        # @param except [Array<Symbol>] groups to drop
        # @param integration_types [Array<Symbol>, nil] integrations to keep,
        #   by lock key (nil = all)
        # @return [Array<Dependency>] in lockfile order
        sig do
          params(
            deps: T::Array[Dependency],
            env: T.nilable(String),
            host: T.nilable(String),
            groups: T.nilable(T::Array[Symbol]),
            except: T::Array[Symbol],
            integration_types: T.nilable(T::Array[Symbol]),
          ).returns(T::Array[Dependency])
        end
        def select(deps, env: nil, host: nil, groups: nil, except: [], integration_types: nil)
          deps.select do |dep|
            matches_scope?(dep.metadata["env"], env) &&
              matches_scope?(dep.metadata["host"], host) &&
              (groups.nil? || groups.include?(dep.group)) &&
              !except.include?(dep.group) &&
              (integration_types.nil? || integration_types.include?(dep.integration))
          end
        end

        private

        # A dep with no scope metadata installs everywhere; a scoped dep only
        # where the detected value matches. No detected value (nil) disables
        # the axis entirely.
        #
        # @param declared [String, nil] the dep's metadata value for the axis
        # @param detected [String, nil] the axis value for this install
        # @return [Boolean]
        sig { params(declared: T.untyped, detected: T.nilable(String)).returns(T::Boolean) }
        def matches_scope?(declared, detected)
          detected.nil? || declared.nil? || declared == detected
        end
      end

      private

      # The selected pins batched per integration INSTANCE, in install order.
      #
      # Batching is by instance rather than by type symbol: types that
      # install through a shared instance (Registry install_alias — e.g. :url
      # deps through :cmake's pipeline) must arrive in one install_all call,
      # or an integration generating batch artifacts (deps.cmake) would
      # overwrite its own output with each partial group. Pins of a type no
      # integration is wired for are dropped. Order is {order}'s.
      #
      # @param deps [Array<Dependency>] the selected pins, in lock order
      # @return [Array<[Integration, Array<Dependency>]>] batches in install order
      # @raise [DependencyCycleError] if the batches' needs form a cycle
      sig { params(deps: T::Array[Dependency]).returns(T::Array[[Integration, T::Array[Dependency]]]) }
      def ordered_batches(deps)
        batches = T.let({}, T::Hash[Integration, T::Array[Dependency]])
        deps.each do |dep|
          integration = @integrations[dep.integration]
          next unless integration

          (batches[integration] ||= []) << dep
        end

        order(batches).map { |integration| [integration, batches.fetch(integration)] }
      end

      # Topological order over the batches' instances. Edges run from the
      # batch that must install first to the one that needs it: the host
      # prerequisite's to every other batch, and a pin's batch to each
      # integration the lock records under its `needed_by` — when that
      # integration has a batch in this install (a need whose user is not
      # selected is still installed, it just orders nothing). Ties keep lock
      # order, so the result is stable run to run.
      #
      # @param batches [Hash{Integration => Array<Dependency>}] in lock order
      # @return [Array<Integration>] the instances, first-to-install first
      # @raise [DependencyCycleError] if the edges form a cycle
      sig { params(batches: T::Hash[Integration, T::Array[Dependency]]).returns(T::Array[Integration]) }
      def order(batches)
        before = T.let({}, T::Hash[Integration, T::Array[Integration]])
        prerequisites, others = batches.keys.partition { |integration| integration.class.host_prerequisite? }
        prerequisites.each { |prerequisite| others.each { |other| (before[other] ||= []) << prerequisite } }
        batches.each do |integration, deps|
          deps.each do |dep|
            Array(dep.metadata[Dependency::NEEDED_BY]).each do |parent|
              needing = @integrations[parent.to_sym]
              (before[needing] ||= []) << integration if needing && batches.key?(needing)
            end
          end
        end

        remaining = batches.keys
        ordered = T.let([], T::Array[Integration])
        until remaining.empty?
          ready = remaining.find { |integration| (before.fetch(integration, []) - ordered).empty? }
          raise DependencyCycleError, cycle_message(remaining.map { |stuck| batches.fetch(stuck) }) if ready.nil?

          ordered << ready
          remaining.delete(ready)
        end
        ordered
      end

      # @param stuck [Array<Array<Dependency>>] the batches no order could place
      # @return [String]
      sig { params(stuck: T::Array[T::Array[Dependency]]).returns(String) }
      def cycle_message(stuck)
        "install order has a cycle among #{stuck.map { |deps| label(deps) }.join(", ")} — " \
          "an integration's needs must be pins of other integrations"
      end

      # Hand one batch to its integration.
      #
      # A failing integration never blocks the others: the graph only orders
      # the attempts, so a batch whose prerequisite failed still runs and
      # reports its own, derivative failure after the root cause. Failures
      # are collected — per-dep entries when the integration isolated them
      # (PartialInstallError), one entry when it failed whole (e.g. a tap
      # registration preamble) — and reported by the caller's aggregate.
      #
      # @param integration [Integration] the batch's instance
      # @param deps [Array<Dependency>] its pins
      # @return [Array<String>] one entry per failure
      sig { params(integration: Integration, deps: T::Array[Dependency]).returns(T::Array[String]) }
      def dispatch(integration, deps)
        integration.install_all(deps)
        []
      rescue Integration::PartialInstallError => e
        e.failures.map { |name, error| "#{label(deps)}: #{name} — #{error.message}" }
      rescue StandardError => e
        ["#{label(deps)}: #{e.message}"]
      end

      # The lock keys a batch spans, joined ("cmake+url").
      #
      # @param deps [Array<Dependency>] one batch
      # @return [String]
      sig { params(deps: T::Array[Dependency]).returns(String) }
      def label(deps)
        deps.map(&:integration).uniq.join("+")
      end
    end
  end
end
