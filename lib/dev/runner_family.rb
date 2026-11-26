# typed: strict
# frozen_string_literal: true

require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_role"
require "dev/runner_slots"

module Dev
  # This host's slots of one role at one scope — the family one `register`
  # enrolls — with what GitHub says of each slot. The subject `dev runner
  # status` frames: a repo-scoped family and an org-scoped one are the
  # same kind of thing, their scope only deciding who fixes their reach.
  #
  # A slot's role is read from the runner group its own `.runner` record
  # names and its GitHub labels, among the roles declared at hand
  # (RunnerRole.for_slot): a declared role when one matches, else a build
  # host (in Default) or a role known by its pool alone. Names and dirs
  # are never parsed for it; they only order the slots within the family.
  class RunnerFamily
    extend T::Sig

    # One slot: the local enrollment and GitHub's record of it — nil when
    # GitHub has lost it, or when GitHub could not be asked (`query_error`
    # says why) — and, for a listed org slot, the group GitHub has it in
    # (`group`; nil when no group lists it, or GitHub was not asked).
    class Slot < T::Struct
      extend T::Sig

      const :enrollment, RunnerDiscovery::Enrollment
      const :runner, T.nilable(RunnerRegistry::Runner)
      const :query_error, T.nilable(String)
      const :group, T.nilable(RunnerRegistry::Group), default: nil

      # Whether GitHub lists the slot.
      sig { returns(T::Boolean) }
      def listed?
        !runner.nil?
      end

      # Whether GitHub was asked and has no such runner: a stale
      # enrollment.
      sig { returns(T::Boolean) }
      def lost?
        runner.nil? && query_error.nil?
      end

      # The role the slot plays among the roles declared at hand: by its
      # pool and, when GitHub lists it, its labels (RunnerRole.for_slot).
      # The pool is the group GitHub has the slot in when that was read;
      # else the `.runner` record's — the group config.sh registered into,
      # which a slot since moved between groups (RunnerGroups#place!)
      # still names.
      #
      # @param declared [Hash{String => Dev::RunnerRole}] the roles declared at hand, by name
      # @return [Dev::RunnerRole]
      sig { params(declared: T::Hash[String, RunnerRole]).returns(RunnerRole) }
      def role(declared)
        RunnerRole.for_slot(pool: group&.name || enrollment.pool, labels: runner&.custom_labels, declared: declared, registered: enrollment.pool)
      end

      # The slot's number among its family's names: 1 for `<base>`, n for
      # `<base>-<n>` (RunnerSlots' shape).
      sig { returns(Integer) }
      def number
        match = RunnerSlots::SLOT_NAME.match(enrollment.name)
        match ? Integer(T.must(match[:slot])) : 1
      end

      # The slot's place among its family's names: by base, slot 1 first.
      #
      # @return [Array] the base, then the number
      sig { returns([String, Integer]) }
      def order_key
        [RunnerSlots.base_of(enrollment.name), number]
      end
    end

    # "owner/repo" (repo scope) or "owner" (org scope).
    sig { returns(String) }
    attr_reader :scope

    sig { returns(RunnerRole) }
    attr_reader :role

    # Slot 1 first, then by number.
    sig { returns(T::Array[Slot]) }
    attr_reader :slots

    class << self
      extend T::Sig

      # The families the slots form: one per (scope, role), declared and
      # pooled roles by name, the build host last, then by scope, so the
      # eye learns positions. A family's role is the first listed slot's —
      # whose labels say which capabilities the family advertises — or,
      # with none listed, the first slot's by pool.
      #
      # @param slots [Array<Slot>] this host's enrollments, each with GitHub's record
      # @param declared [Hash{String => Dev::RunnerRole}] the roles declared at hand, by name
      # @return [Array<Dev::RunnerFamily>]
      sig { params(slots: T::Array[Slot], declared: T::Hash[String, RunnerRole]).returns(T::Array[RunnerFamily]) }
      def of(slots, declared: {})
        grouped = slots.group_by { |slot| [slot.enrollment.scope, slot.role(declared).name] }
        families = grouped.map do |(scope, _role_name), members|
          ordered = members.sort_by(&:order_key)
          role = (ordered.find(&:listed?) || T.must(ordered.first)).role(declared)
          new(scope: scope, role: role, slots: ordered)
        end
        families.sort_by { |family| [family.role.build_host? ? 1 : 0, family.role.name, family.scope] }
      end
    end

    # @param scope [String]
    # @param role [Dev::RunnerRole]
    # @param slots [Array<Slot>] ordered
    sig { params(scope: String, role: RunnerRole, slots: T::Array[Slot]).void }
    def initialize(scope:, role:, slots:)
      @scope = scope
      @role = role
      @slots = slots
    end

    # Whether the family is registered at an org (its reach fixed by a
    # runner group) rather than at a repo.
    sig { returns(T::Boolean) }
    def org_scoped?
      !@scope.include?("/")
    end

    # The org the scope belongs to: the scope itself, or the repo's owner.
    sig { returns(String) }
    def org
      T.must(@scope.split("/").first)
    end

    # The first slot GitHub lists — whose record speaks for the family's
    # labels and group — or nil when it lists none.
    sig { returns(T.nilable(Slot)) }
    def first_listed
      @slots.find(&:listed?)
    end

    # Whether the slots were asked of GitHub and it could not answer.
    #
    # @return [String, nil] the query error, when there was one
    sig { returns(T.nilable(String)) }
    def query_error
      @slots.filter_map(&:query_error).first
    end
  end
end
