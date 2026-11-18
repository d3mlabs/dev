# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "brew_repository"
require_relative "dependency"
require_relative "package_version"
require_relative "resolver"
require_relative "scoped_declaration"
require_relative "unlock_set"
require_relative "version_scheme"

module Dev
  module Deps
    # The lock-writing rule that decides, pin by pin, whether the lock being
    # written takes the pin the Resolver just minted or carries the one the
    # lock on disk already has. One rule for every channel.
    #
    # A bare `dev deps update` floats everything: every pin is the
    # resolution's, at the newest version its declaration admits. Nothing
    # is kept.
    #
    # `dev deps update <name>…` floats the named declarations and what they
    # pull in through integration needs, and decides the rest: a pin the
    # lock did not have is new; a pin whose declaration changed — another
    # group, scope or source, or a requirement the locked version no longer
    # satisfies — is re-resolved; an unchanged pin the lock records a
    # `source` for is kept, byte for byte; an unchanged pin without one
    # cannot be kept (nothing says what exactly it was) and is re-resolved,
    # with that said once. Every move is reported with its reason.
    #
    # Provenance — a pin's `source`, and metadata that records where it was
    # resolved from rather than what it is (brew's `tap_commit`) — moves
    # only when the pin does: a re-resolved pin whose facts are the lock's
    # keeps the lock's provenance, so a re-lock that changes no version
    # changes no lock line.
    #
    # A subset re-lock needs nothing from today's universe for a pin it
    # keeps, so when the universe did not answer for such a declaration the
    # lock's pin stands, reported as kept for want of an answer. Every other
    # shape needs today's answer, and the repository's failure propagates.
    #
    # Pure over the declarations, the previous lock and the resolution; the
    # Resolver never sees the previous lock.
    class PinCarryover
      extend T::Sig

      # Per channel, the metadata key under which a pin records the source
      # its declaration named (PackageId#source): brew's tap, a git or
      # GitHub repository, an image's floor, a Steam app, a URL. A channel
      # absent here has no declared source — the name is the whole
      # coordinate (pip, gems, rocks, mods, casks, the addressable ones).
      DECLARED_SOURCE_KEYS = T.let(
        {
          brew: "tap", ruby: "tap", python: "tap",
          cmake: "repo", gh: "repo",
          image: "from",
          steam: "app",
          url: "url", egs: "url",
        }.freeze,
        T::Hash[Symbol, String],
      )

      # The image channel, whose declared source carries the tag too
      # (`<floor>:<tag>`): the pin's version is the tag.
      IMAGE_INTEGRATION = :image

      # Metadata that records where a pin was resolved from rather than
      # what it is. It rides with the pin's source, and a re-resolved pin
      # whose facts did not change keeps the lock's.
      PROVENANCE_KEYS = T.let([BrewRepository::TAP_COMMIT].freeze, T::Array[String])

      # A pin the lock takes from the resolution at another version than it
      # had (`from` nil when the lock had none), and why — nil when the
      # bare verb asked for every pin to move.
      class Move < T::Struct
        const :name, String
        const :from, T.nilable(String)
        const :to, T.nilable(String)
        const :reason, T.nilable(String), default: nil
      end

      # A pin the lock keeps for want of an answer: the declaration's
      # repository failed, and the re-lock would have carried the lock's pin
      # whatever it answered.
      class Unreachable < T::Struct
        const :pin, Dependency
        const :error, StandardError
      end

      # What the lock being written holds, and how it got there: the pins,
      # which of them are the lock on disk's (kept, and kept because the
      # universe did not answer), and which moved.
      class Outcome < T::Struct
        const :pins, T::Array[Dependency]
        const :kept, T::Array[Dependency]
        const :moved, T::Array[Move]
        const :unreachable, T::Array[Unreachable]
      end

      # One pin's verdict.
      class Decision < T::Struct
        const :pin, Dependency
        const :kept, T::Boolean, default: false
        const :move, T.nilable(Move), default: nil
        const :unreachable, T.nilable(StandardError), default: nil
      end

      # @param schemes [Hash{Symbol => VersionScheme}] integration → its
      #   requirement semantics (Registry.schemes), asked whether a locked
      #   version still satisfies its declaration
      sig { params(schemes: T::Hash[Symbol, VersionScheme]).void }
      def initialize(schemes:)
        @schemes = schemes
      end

      # @param declarations [Array<ScopedDeclaration>] every declaration the
      #   resolution answered — the project's and the integration needs'
      # @param previous [Array<Dependency>] the pins the lock on disk carries
      # @param resolved [Array<Dependency, Resolver::Unresolved>] the
      #   resolution's verdicts: the pins just resolved, and the declarations
      #   whose universe did not answer
      # @param unlock [UnlockSet] which declarations the author floats
      # @return [Outcome] resolved, pin for pin, with the lock's pins carried
      #   where the rule says so
      # @raise [StandardError] the repository's failure for an unresolved
      #   declaration whose pin the lock cannot carry
      sig do
        params(
          declarations: T::Array[ScopedDeclaration],
          previous: T::Array[Dependency],
          resolved: T::Array[Resolver::Verdict],
          unlock: UnlockSet,
        ).returns(Outcome)
      end
      def apply(declarations:, previous:, resolved:, unlock:)
        before = previous.to_h { |dep| [identity(dep), dep] }
        asks = declarations.each_with_object({}) { |decl, acc| acc[[decl.integration, decl.name]] ||= decl }
        floated_integrations = declarations.select { |decl| unlock.floats?(decl.name) }.map { |decl| decl.integration.to_s }.uniq

        decisions = resolved.map do |verdict|
          case verdict
          when Dependency
            floats = floats?(verdict.name, needed_by(verdict), floated_integrations, unlock)
            decide(verdict, before[identity(verdict)], asks[identity(verdict)], floats:, unlock:)
          when Resolver::Unresolved
            decl = verdict.declaration
            floats = floats?(decl.name, verdict.needed_by, floated_integrations, unlock)
            decide_unresolved(verdict, before[[decl.integration, decl.name]], floats:, unlock:)
          else
            T.absurd(verdict)
          end
        end

        Outcome.new(
          pins: decisions.map(&:pin),
          kept: decisions.select(&:kept).map(&:pin),
          moved: decisions.filter_map(&:move),
          unreachable: decisions.filter_map do |decision|
            error = decision.unreachable
            Unreachable.new(pin: decision.pin, error:) if error
          end,
        )
      end

      private

      # Whether the author asked for a pin to float: by name, or through an
      # integration that needs it being named.
      #
      # @param name [String] the pin's name
      # @param needed_by [Array<String>] the integrations whose manifests need it
      # @param floated_integrations [Array<String>] the integrations with a named declaration
      # @param unlock [UnlockSet]
      # @return [Boolean]
      sig do
        params(name: String, needed_by: T::Array[String], floated_integrations: T::Array[String], unlock: UnlockSet)
          .returns(T::Boolean)
      end
      def floats?(name, needed_by, floated_integrations, unlock)
        unlock.floats?(name) || (needed_by & floated_integrations).any?
      end

      # The rule for a resolved pin: new pins and floated pins are the
      # resolution's; a changed declaration re-resolves; an unchanged one is
      # kept when the lock records what exactly it was, else floats with
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
      def decide(dep, prior, ask, floats:, unlock:)
        return Decision.new(pin: dep, move: Move.new(name: dep.name, from: nil, to: dep.version, reason: "new")) if prior.nil?
        return re_resolved(dep, prior, reason: unlock.subset? ? "named" : nil) if floats
        return re_resolved(dep, prior, reason: "declaration changed") unless ask && declaration_unchanged?(prior, ask)
        return Decision.new(pin: carried(dep, prior), kept: true) if prior.source

        re_resolved(dep, prior, reason: "the lock records no source for #{prior.version}, so it cannot be kept")
      end

      # The rule for a declaration whose universe did not answer. A subset
      # re-lock would carry an unfloated, unchanged pin the lock has
      # whatever today's answer — so none is needed, and the lock's pin
      # stands, kept for want of an answer. Everything else needs the
      # answer that never came, and the repository's failure is the
      # re-lock's.
      #
      # @param unresolved [Resolver::Unresolved] the declaration and the failure
      # @param prior [Dependency, nil] the lock's pin of the same identity
      # @param floats [Boolean] whether the author asked for it to float
      # @param unlock [UnlockSet]
      # @return [Decision]
      # @raise [StandardError] the repository's failure, when the pin cannot be carried
      sig do
        params(
          unresolved: Resolver::Unresolved,
          prior: T.nilable(Dependency),
          floats: T::Boolean,
          unlock: UnlockSet,
        ).returns(Decision)
      end
      def decide_unresolved(unresolved, prior, floats:, unlock:)
        carried = unlock.subset? && prior && !floats && declaration_unchanged?(prior, unresolved.declaration)
        raise unresolved.error unless carried

        Decision.new(pin: prior, unreachable: unresolved.error)
      end

      # The resolution's pin, moved when its version differs from the
      # lock's, and carrying the lock's provenance when nothing else about
      # it changed (a source at which the pin was what the lock says is as
      # good as today's, and does not move the lock).
      #
      # @param dep [Dependency] the resolved pin
      # @param prior [Dependency] the lock's pin
      # @param reason [String, nil] why it floated; nil when the bare verb asked
      # @return [Decision]
      sig { params(dep: Dependency, prior: Dependency, reason: T.nilable(String)).returns(Decision) }
      def re_resolved(dep, prior, reason:)
        pin = facts(dep) == facts(prior) ? with_provenance(dep, prior) : dep
        move = dep.version == prior.version ? nil : Move.new(name: dep.name, from: prior.version, to: dep.version, reason:)
        Decision.new(pin:, move:)
      end

      # The resolution's pin with the lock's provenance, where the lock has
      # any: its source, and its provenance metadata.
      #
      # @param dep [Dependency] the resolved pin
      # @param prior [Dependency] the lock's pin, whose facts are dep's
      # @return [Dependency]
      sig { params(dep: Dependency, prior: Dependency).returns(Dependency) }
      def with_provenance(dep, prior)
        dep.with(
          source: prior.source || dep.source,
          metadata: dep.metadata.merge(prior.metadata.slice(*PROVENANCE_KEYS)),
        )
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
          source: prior.source,
          metadata: prior.metadata.except(Dependency::NEEDED_BY).merge(dep.metadata.slice(Dependency::NEEDED_BY)),
        )
      end

      # Whether the declaration still asks what the lock's pin answered:
      # same group, same scope (host, env), the same declared source, and
      # an ask the locked version still satisfies — the declaration's
      # revision, or its requirement under the integration's scheme.
      #
      # @param prior [Dependency] the lock's pin
      # @param ask [ScopedDeclaration] the declaration
      # @return [Boolean]
      sig { params(prior: Dependency, ask: ScopedDeclaration).returns(T::Boolean) }
      def declaration_unchanged?(prior, ask)
        [
          prior.group == ask.scope.group,
          scope_of(prior) == ask.scope.to_metadata,
          resolved_from?(prior, ask),
          still_asked?(prior, ask),
        ].all?
      end

      # Whether the lock's pin was resolved from the source the declaration
      # names, read from the metadata the pin's channel records it under.
      # An image pin records its floor and resolved its tag, so the two
      # together are the declared reference; a channel with no declared
      # source has nothing to compare, and the name's agreement is the
      # identity's.
      #
      # @param prior [Dependency] the lock's pin
      # @param ask [ScopedDeclaration] the declaration
      # @return [Boolean]
      sig { params(prior: Dependency, ask: ScopedDeclaration).returns(T::Boolean) }
      def resolved_from?(prior, ask)
        key = DECLARED_SOURCE_KEYS[prior.integration]
        return true if key.nil?

        declared = prior.metadata[key]
        declared = "#{declared}:#{prior.version}" if prior.integration == IMAGE_INTEGRATION
        declared == ask.source
      end

      # Whether the locked version is what the declaration asks for: the
      # revision it addresses, or a version its requirement admits.
      #
      # @param prior [Dependency] the lock's pin
      # @param ask [ScopedDeclaration] the declaration
      # @return [Boolean]
      sig { params(prior: Dependency, ask: ScopedDeclaration).returns(T::Boolean) }
      def still_asked?(prior, ask)
        revision = ask.revision
        return prior.version == revision if revision

        satisfies?(ask, prior)
      end

      # @param ask [ScopedDeclaration]
      # @param prior [Dependency] the lock's pin, read as a version of the universe
      # @return [Boolean] whether the locked version satisfies the ask
      sig { params(ask: ScopedDeclaration, prior: Dependency).returns(T::Boolean) }
      def satisfies?(ask, prior)
        locked = prior.version
        return false if locked.nil?

        scheme = @schemes[ask.integration]
        return ask.requirement.any? if scheme.nil?

        scheme.satisfies?(PackageVersion.new(version: locked, metadata: prior.metadata), ask.requirement)
      rescue VersionScheme::InvalidVersionError
        false
      end

      # Everything the lock says about a pin but where it came from and
      # who needs it.
      #
      # @param dep [Dependency]
      # @return [Array] the pin's fact tuple
      sig { params(dep: Dependency).returns(T::Array[T.untyped]) }
      def facts(dep)
        [dep.version, dep.hash, dep.group, dep.metadata.except(*PROVENANCE_KEYS, Dependency::NEEDED_BY)]
      end

      # @param dep [Dependency]
      # @return [Hash{String => String}] the pin's install scoping (host, env)
      sig { params(dep: Dependency).returns(T::Hash[String, T.untyped]) }
      def scope_of(dep)
        dep.metadata.slice("host", "env")
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
