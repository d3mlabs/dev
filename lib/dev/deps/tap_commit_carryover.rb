# typed: strict
# frozen_string_literal: true

require_relative "brew_repository"
require_relative "dependency"

module Dev
  module Deps
    # The lock-writing rule that keeps a brew pin's `tap_commit` still while
    # its tap's pins are: `dev deps update` carries the previous lock's
    # commit for every tap none of whose pins changed, and stamps today's
    # tap HEAD only on taps where something moved.
    #
    # `tap_commit` is provenance, not an install fact. It says where a pin
    # came from — a commit of the tap at which its formulae are what the
    # lock says they are — and the previous lock's commit satisfies that
    # whenever the tap's pins have not changed. Without this rule every
    # `dev deps update` after a `brew update` rewrote the commit on every
    # core formula, and because the build image is content-addressed on
    # `build-deps.lock`, bumping a gem rebuilt the build toolchain's image.
    #
    # Per tap, not per formula: a pinned install checks a tap out once
    # (BrewIntegration#pin_taps! requires one commit per tap), so one changed
    # formula moves the whole tap. Across both lockfiles, for the same
    # reason — a host's pinned install reads both.
    #
    # Pure over two pin lists; the Resolver never sees the previous lock.
    class TapCommitCarryover
      extend T::Sig

      TAP_COMMIT = "tap_commit"

      # @param resolved [Array<Dependency>] the pins just resolved
      # @param previous [Array<Dependency>] the pins the lock on disk carries
      # @return [Array<Dependency>] resolved, with every unchanged tap's pins
      #   carrying the previous lock's commit; other pins are the same objects
      sig { params(resolved: T::Array[Dependency], previous: T::Array[Dependency]).returns(T::Array[Dependency]) }
      def apply(resolved, previous)
        kept = kept_commits(resolved, previous)
        resolved.map do |dep|
          commit = formula?(dep) ? kept[tap_of(dep)] : nil
          commit ? dep.with(metadata: metadata_of(dep).merge(TAP_COMMIT => commit)) : dep
        end
      end

      private

      # The previous lock's commit for every tap whose pins are unchanged and
      # whose previous pins agree on one commit (a lock pinning a tap at two
      # commits is a merge artifact; today's HEAD heals it rather than
      # preserving it).
      #
      # @param resolved [Array<Dependency>]
      # @param previous [Array<Dependency>]
      # @return [Hash{String => String}] tap => commit to carry
      sig { params(resolved: T::Array[Dependency], previous: T::Array[Dependency]).returns(T::Hash[String, String]) }
      def kept_commits(resolved, previous)
        before = formulae_by_tap(previous)
        formulae_by_tap(resolved).filter_map do |tap, pins|
          prior = before[tap]
          next unless prior && facts(pins) == facts(prior)

          commits = prior.map { |dep| metadata_of(dep)[TAP_COMMIT] }.uniq
          commit = commits.first
          next unless commits.length == 1 && commit

          [tap, commit]
        end.to_h
      end

      # @param deps [Array<Dependency>]
      # @return [Hash{String => Array<Dependency>}] tap => its formula pins
      sig { params(deps: T::Array[Dependency]).returns(T::Hash[String, T::Array[Dependency]]) }
      def formulae_by_tap(deps)
        deps.select { |dep| formula?(dep) }.group_by { |dep| tap_of(dep) }
      end

      # @param dep [Dependency]
      # @return [Boolean] a brew formula (casks pin no tap commit)
      sig { params(dep: Dependency).returns(T::Boolean) }
      def formula?(dep)
        dep.integration == :brew && !metadata_of(dep)["cask"]
      end

      # @param dep [Dependency]
      # @return [String] the formula's tap, core when untapped
      sig { params(dep: Dependency).returns(String) }
      def tap_of(dep)
        metadata_of(dep)["tap"] || BrewRepository::CORE_TAP
      end

      # @param dep [Dependency]
      # @return [Hash] the pin's metadata, never nil
      sig { params(dep: Dependency).returns(T::Hash[String, T.untyped]) }
      def metadata_of(dep)
        dep.metadata || {}
      end

      # Everything the lock says about a tap's pins except where they came
      # from, in an order that does not depend on resolution order.
      #
      # @param pins [Array<Dependency>]
      # @return [Array<Array>] one fact tuple per pin
      sig { params(pins: T::Array[Dependency]).returns(T::Array[T::Array[T.untyped]]) }
      def facts(pins)
        pins
          .map { |dep| [dep.name, dep.group.to_s, metadata_of(dep)["env"].to_s, dep.version, dep.hash, metadata_of(dep).except(TAP_COMMIT)] }
          .sort_by { |tuple| tuple.first(3) }
      end
    end
  end
end
