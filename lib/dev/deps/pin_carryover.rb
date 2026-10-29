# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "brew_repository"
require_relative "dependency"
require_relative "package_version"
require_relative "scoped_declaration"
require_relative "unlock_set"
require_relative "version_scheme"

module Dev
  module Deps
    # The lock-writing rule that decides, pin by pin, whether the lock being
    # written takes the pin the Resolver just minted or carries the one the
    # lock on disk already has — `bundle install`'s resolution against an
    # existing Gemfile.lock (plans#50 D3), applied to the brew channel.
    #
    # Brew is a moving registry: every `dev deps update` on a machine whose
    # index is ahead of the lock re-resolved every formula to today's
    # version, so adding one `gh` entry moved `python@3.12` and `cmake` in
    # the same diff (cellbound-3d#319, dev#355). A declaration that did not
    # change should not produce a different pin. So a brew pin — a formula
    # or an interpreter; casks pin no version — keeps the lock's version
    # when its declaration is unchanged (same tap, same scope, and the
    # locked version still satisfies its constraint) and the lock can
    # converge a host to that version: it records the `tap_commit` at
    # which the formula is that version, and `dev up` installs from the
    # tap checked out there (dev#356). It floats when the author asked
    # (the UnlockSet: `dev deps update <name>`, `--all`), when the
    # declaration changed, or when the lock records no tap commit — the
    # one move the author did not ask for, reported with its reason.
    #
    # `tap_commit` rides the pin (ADR-0005, refined by dev#355): a kept pin
    # keeps the commit it was resolved at — a commit where its formula is
    # what the lock says — and a re-resolved pin takes today's HEAD unless
    # nothing about it changed, in which case the previous commit still
    # describes it. The unit is the pin, not the tap: a tap whose pins moved
    # at different times carries several commits, which a pinned install
    # refuses (BrewIntegration#pin_taps!) with `--all` as the remediation.
    #
    # A subset re-lock carries every pin it did not float verbatim from the
    # lock on disk, whatever its channel — `bundle update <gem>`.
    #
    # Pure over the declarations, the previous lock and the resolution; the
    # Resolver never sees the previous lock.
    class PinCarryover
      extend T::Sig

      # The pins brew installs with a version: formulae and the interpreters
      # that are formulae (Registry's `install_alias: :brew` rows).
      BREW_INTEGRATIONS = T.let(%i[brew ruby python].freeze, T::Array[Symbol])
      TAP_COMMIT = "tap_commit"

      # A pin the lock takes from the resolution at another version than it
      # had (`from` nil when the lock had none), and why.
      class Move < T::Struct
        const :name, String
        const :from, T.nilable(String)
        const :to, T.nilable(String)
        const :reason, String
      end

      # What the lock being written holds, and how it got there: the pins,
      # which of them are the lock on disk's (kept), and which moved.
      class Outcome < T::Struct
        const :pins, T::Array[Dependency]
        const :kept, T::Array[Dependency]
        const :moved, T::Array[Move]
      end

      # One pin's verdict.
      class Decision < T::Struct
        const :pin, Dependency
        const :kept, T::Boolean, default: false
        const :move, T.nilable(Move), default: nil
      end

      # @param schemes [Hash{Symbol => VersionScheme}] integration → its
      #   constraint semantics (Registry.schemes), asked whether a locked
      #   version still satisfies its declaration
      sig { params(schemes: T::Hash[Symbol, VersionScheme]).void }
      def initialize(schemes:)
        @schemes = schemes
      end

      # @param declarations [Array<ScopedDeclaration>] every declaration the
      #   resolution answered — the project's and the integration needs'
      # @param previous [Array<Dependency>] the pins the lock on disk carries
      # @param resolved [Array<Dependency>] the pins just resolved
      # @param unlock [UnlockSet] which declarations the author floats
      # @return [Outcome] resolved, pin for pin, with the lock's pins carried
      #   where the rule says so
      sig do
        params(
          declarations: T::Array[ScopedDeclaration],
          previous: T::Array[Dependency],
          resolved: T::Array[Dependency],
          unlock: UnlockSet,
        ).returns(Outcome)
      end
      def apply(declarations:, previous:, resolved:, unlock:)
        before = previous.to_h { |dep| [identity(dep), dep] }
        asks = declarations.each_with_object({}) { |decl, acc| acc[[decl.integration, decl.name]] ||= decl }
        floated_integrations = declarations.select { |decl| unlock.floats?(decl.name) }.map { |decl| decl.integration.to_s }.uniq

        decisions = resolved.map do |dep|
          prior = before[identity(dep)]
          floats = unlock.floats?(dep.name) || (needed_by(dep) & floated_integrations).any?
          if BREW_INTEGRATIONS.include?(dep.integration)
            decide_brew(dep, prior, asks[identity(dep)], floats:, unlock:)
          elsif unlock.subset? && prior && !floats
            Decision.new(pin: prior, kept: true)
          else
            Decision.new(pin: dep)
          end
        end

        Outcome.new(
          pins: decisions.map(&:pin),
          kept: decisions.select(&:kept).map(&:pin),
          moved: decisions.filter_map(&:move),
        )
      end

      private

      # The brew rule: new pins and floated pins are the resolution's; a
      # changed declaration re-resolves; an unchanged one keeps the lock's
      # version when the lock can converge a host to it, else floats with
      # the reason.
      #
      # @param dep [Dependency] the resolved pin
      # @param prior [Dependency, nil] the lock's pin of the same identity
      # @param ask [ScopedDeclaration, nil] the declaration it answers
      # @param floats [Boolean] whether the author asked for it to float
      # @param unlock [UnlockSet] for the reason's wording
      # @return [Decision]
      sig do
        params(
          dep: Dependency,
          prior: T.nilable(Dependency),
          ask: T.nilable(ScopedDeclaration),
          floats: T::Boolean,
          unlock: UnlockSet,
        ).returns(Decision)
      end
      def decide_brew(dep, prior, ask, floats:, unlock:)
        return Decision.new(pin: dep, move: Move.new(name: dep.name, from: nil, to: dep.version, reason: "new")) if prior.nil?
        return re_resolved(dep, prior, reason: unlock.all? ? "--all" : "named") if floats
        return re_resolved(dep, prior, reason: "declaration changed") unless ask && declaration_unchanged?(dep, prior, ask)
        return Decision.new(pin: carried(dep, prior), kept: true) if convergeable?(prior)

        re_resolved(
          dep, prior,
          reason: "the lock records no tap commit for #{prior.version}, so no host could converge to it",
        )
      end

      # The resolution's pin, moved when its version differs from the
      # lock's, and carrying the lock's `tap_commit` when nothing else about
      # it changed (a commit at which the formula was what the lock says is
      # as good as today's, and does not move the lock).
      #
      # @param dep [Dependency] the resolved pin
      # @param prior [Dependency] the lock's pin
      # @param reason [String] why it floated
      # @return [Decision]
      sig { params(dep: Dependency, prior: Dependency, reason: String).returns(Decision) }
      def re_resolved(dep, prior, reason:)
        commit = prior.metadata[TAP_COMMIT]
        pin = commit && facts(dep) == facts(prior) ? dep.with(metadata: dep.metadata.merge(TAP_COMMIT => commit)) : dep
        move = dep.version == prior.version ? nil : Move.new(name: dep.name, from: prior.version, to: dep.version, reason:)
        Decision.new(pin:, move:)
      end

      # The lock's pin, with the resolution's provenance: who needs it is a
      # fact of this resolution, everything else is what the lock says.
      #
      # @param dep [Dependency] the resolved pin
      # @param prior [Dependency] the lock's pin
      # @return [Dependency]
      sig { params(dep: Dependency, prior: Dependency).returns(Dependency) }
      def carried(dep, prior)
        dep.with(
          version: prior.version,
          hash: prior.hash,
          metadata: prior.metadata.except(Dependency::NEEDED_BY).merge(dep.metadata.slice(Dependency::NEEDED_BY)),
        )
      end

      # Whether the declaration still asks what the lock's pin answered:
      # same tap, same scope (group, host, env), and a constraint the locked
      # version satisfies under the integration's scheme.
      #
      # @param dep [Dependency] the resolved pin (its tap and scope are the declaration's)
      # @param prior [Dependency] the lock's pin
      # @param ask [ScopedDeclaration] the declaration
      # @return [Boolean]
      sig { params(dep: Dependency, prior: Dependency, ask: ScopedDeclaration).returns(T::Boolean) }
      def declaration_unchanged?(dep, prior, ask)
        same_shape = [dep.group == prior.group, scope_of(dep) == scope_of(prior), tap_of(dep) == tap_of(prior)].all?
        same_shape && satisfies?(ask, prior)
      end

      # @param ask [ScopedDeclaration]
      # @param prior [Dependency] the lock's pin, read as a version of the universe
      # @return [Boolean] whether the locked version satisfies the ask
      sig { params(ask: ScopedDeclaration, prior: Dependency).returns(T::Boolean) }
      def satisfies?(ask, prior)
        locked = prior.version
        return false if locked.nil?

        scheme = @schemes[ask.integration]
        return ask.constraint.empty? if scheme.nil?

        scheme.satisfies?(PackageVersion.new(version: locked, metadata: prior.metadata), ask.constraint)
      rescue VersionScheme::InvalidVersionError
        false
      end

      # Whether a host can be converged to the lock's version: the lock
      # records the tap commit at which the formula is that version, and
      # `dev up` installs it from the tap checked out there (dev#356) —
      # bottles or not. A pin written before tap commits were recorded
      # leaves a host only `brew upgrade`, which reaches today's version
      # and no other.
      #
      # @param prior [Dependency] the lock's pin
      # @return [Boolean]
      sig { params(prior: Dependency).returns(T::Boolean) }
      def convergeable?(prior)
        !prior.metadata[TAP_COMMIT].to_s.empty?
      end

      # Everything the lock says about a pin but where it came from and
      # who needs it.
      #
      # @param dep [Dependency]
      # @return [Array] the pin's fact tuple
      sig { params(dep: Dependency).returns(T::Array[T.untyped]) }
      def facts(dep)
        [dep.version, dep.hash, dep.group, dep.metadata.except(TAP_COMMIT, Dependency::NEEDED_BY)]
      end

      # @param dep [Dependency]
      # @return [Hash{String => String}] the pin's install scoping (host, env)
      sig { params(dep: Dependency).returns(T::Hash[String, T.untyped]) }
      def scope_of(dep)
        dep.metadata.slice("host", "env")
      end

      # @param dep [Dependency]
      # @return [String] the formula's tap, core when untapped
      sig { params(dep: Dependency).returns(String) }
      def tap_of(dep)
        dep.metadata["tap"] || BrewRepository::CORE_TAP
      end

      # @param dep [Dependency]
      # @return [Array<String>] the integrations whose manifests need the pin
      sig { params(dep: Dependency).returns(T::Array[String]) }
      def needed_by(dep)
        Array(dep.metadata[Dependency::NEEDED_BY]).map(&:to_s)
      end

      # @param dep [Dependency]
      # @return [Array(Symbol, String)] the lock's identity for the pin
      sig { params(dep: Dependency).returns([Symbol, String]) }
      def identity(dep)
        [dep.integration, dep.name]
      end
    end
  end
end
