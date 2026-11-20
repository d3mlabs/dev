# typed: strict
# frozen_string_literal: true

require "set"

require "dev/reach"
require "dev/runner_registry"

module Dev
  # One family's reach as GitHub fixes it, held against what its role
  # obliges (RunnerRole#expected_reach): the one fact `dev runner status`
  # prints per family, in three clauses — from which repos, via which
  # workflows, selected by which labels.
  #
  # The repos clause compares by shape — every repo, a selection, or no
  # repo at all — never by membership: which repos a selection admits is
  # each checkout's `register` run, and whether *this* checkout is among
  # them is the invocation's line, not a drift of the family. Workflows
  # and labels compare as sets.
  #
  # What fixes the observed reach — a repo registration, or the org
  # group the slots sit in — is carried as provenance and printed only
  # as evidence under a drift: the operator asked whose jobs can land,
  # not which GitHub mechanism answers.
  class ReachFact
    extend T::Sig

    # A repo-scoped registration: the repo's own workflows, no pin, and
    # nothing but an org registration can change that.
    class RepoRegistration < T::Struct
      extend T::Sig

      const :repo, String

      # @return [String] the mechanism, as a ✗ line's cause
      sig { returns(String) }
      def evidence
        "reach is fixed by the repo registration at #{repo} (its own workflows, no pin) — " \
          "only an org registration in a group can widen or pin it"
      end
    end

    # An org registration: the group the slots sit in fixes who sees
    # them and which workflows may land.
    class GroupPlacement < T::Struct
      extend T::Sig

      const :group, RunnerRegistry::Group

      # @return [String] the mechanism, as a ✗ line's cause
      sig { returns(String) }
      def evidence
        pin = if group.restricted_to_workflows
          "restricted to #{group.selected_workflows.length} workflow#{"s" unless group.selected_workflows.length == 1}"
        else
          "not restricted to workflows"
        end
        "slots sit in org group `#{group.name}` (visibility #{group.visibility}, #{pin})"
      end
    end

    Provenance = T.type_alias { T.any(RepoRegistration, GroupPlacement) }

    # The clauses, in the order the fact prints them.
    CLAUSES = T.let([:repos, :workflows, :labels].freeze, T::Array[Symbol])

    sig { returns(Reach) }
    attr_reader :observed

    sig { returns(Provenance) }
    attr_reader :fixed_by

    # What the role obliges; nil when the role refused the target
    # (`exposure`), or when no declaration of the role is at hand to say
    # (`unverified?`).
    sig { returns(T.nilable(Reach)) }
    attr_reader :expected

    # Why the role refuses the observed reach outright: a build host whose
    # repo is public, where any workflow — an approved fork PR's included
    # — may land. nil when the role answered a reach to compare.
    sig { returns(T.nilable(String)) }
    attr_reader :exposure

    class << self
      extend T::Sig

      # The fact for a role that answered an expected reach.
      #
      # @param expected [Dev::Reach] the role's
      # @param observed [Dev::Reach] GitHub's
      # @param fixed_by [RepoRegistration, GroupPlacement] what fixes the observed reach
      # @return [Dev::ReachFact]
      sig { params(expected: Reach, observed: Reach, fixed_by: Provenance).returns(ReachFact) }
      def compare(expected:, observed:, fixed_by:)
        new(expected: expected, exposure: nil, observed: observed, fixed_by: fixed_by)
      end

      # The fact for a role that refused the target (Reach::ExposedError).
      #
      # @param exposure [String] the refusal's reason
      # @param observed [Dev::Reach] GitHub's
      # @param fixed_by [RepoRegistration, GroupPlacement] what fixes the observed reach
      # @return [Dev::ReachFact]
      sig { params(exposure: String, observed: Reach, fixed_by: Provenance).returns(ReachFact) }
      def exposed(exposure:, observed:, fixed_by:)
        new(expected: nil, exposure: exposure, observed: observed, fixed_by: fixed_by)
      end

      # The fact for a family known by its pool alone (RunnerRole.pooled):
      # GitHub's reach is read, but no declaration is at hand to hold it
      # against — the declaring checkout's `dev runner status` can.
      #
      # @param observed [Dev::Reach] GitHub's
      # @param fixed_by [GroupPlacement] the group the slots sit in
      # @return [Dev::ReachFact]
      sig { params(observed: Reach, fixed_by: Provenance).returns(ReachFact) }
      def unverified(observed:, fixed_by:)
        new(expected: nil, exposure: nil, observed: observed, fixed_by: fixed_by)
      end
    end

    # @param expected [Dev::Reach, nil]
    # @param exposure [String, nil]
    # @param observed [Dev::Reach]
    # @param fixed_by [RepoRegistration, GroupPlacement]
    sig { params(expected: T.nilable(Reach), exposure: T.nilable(String), observed: Reach, fixed_by: Provenance).void }
    def initialize(expected:, exposure:, observed:, fixed_by:)
      @expected = expected
      @exposure = exposure
      @observed = observed
      @fixed_by = fixed_by
    end

    private_class_method :new

    # Whether the role refused the target rather than answer a reach.
    sig { returns(T::Boolean) }
    def exposed?
      !@exposure.nil?
    end

    # Whether GitHub's reach was read with nothing to hold it against.
    sig { returns(T::Boolean) }
    def unverified?
      @expected.nil? && @exposure.nil?
    end

    # The clauses where GitHub's reach departs from the role's, in
    # CLAUSES order; empty when they agree or when the role refused.
    #
    # @return [Array<Symbol>] of :repos, :workflows, :labels
    sig { returns(T::Array[Symbol]) }
    def drift
      expected = @expected
      return [] if expected.nil?

      drifted = []
      drifted << :repos if repos_drifted?(expected, @observed)
      drifted << :workflows unless expected.workflows == @observed.workflows
      drifted << :labels unless expected.labels == @observed.labels
      drifted
    end

    # Whether the family's reach is what its role obliges; never for a
    # fact nothing was held against.
    sig { returns(T::Boolean) }
    def ok?
      !exposed? && !unverified? && drift.empty?
    end

    private

    # The repos clause by shape: a role expecting every repo is met only
    # by an open reach; one expecting a selection by any selection that
    # admits someone.
    #
    # @param expected [Dev::Reach]
    # @param observed [Dev::Reach]
    # @return [Boolean]
    sig { params(expected: Reach, observed: Reach).returns(T::Boolean) }
    def repos_drifted?(expected, observed)
      return !observed.open? if expected.open?

      observed.open? || T.cast(observed.repos, T::Set[String]).empty?
    end
  end
end
