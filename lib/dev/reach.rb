# typed: strict
# frozen_string_literal: true

require "set"
require_relative "value_equality"

module Dev
  # Who may land a job on a runner, as one fact (plans#52, *Decision:
  # `runner status` groups by subject, reach is one fact*): **from** which
  # repos, **via** which workflows, on which **labels**. A repo-scoped and
  # an org-scoped runner are the same GitHub object behind two URL
  # prefixes; the scope only decides who fixes `from` — the repo itself,
  # or a runner group's selection — and a group is the only thing that can
  # carry a workflow pin. So reach is a property of the **role**
  # (RunnerRole#expected_reach), and scope is derived from it.
  class Reach
    extend T::Sig
    include Dev::ValueEquality::Derived

    # Every repository in the org (a group with visibility "all").
    ALL = :all
    # Any workflow at all (no pin — the repo's own workflows, or an
    # unrestricted group).
    ANY = :any

    # The repo a registration is for, and the one fact about it that
    # reach turns on: whether it is public (plans#5 H3).
    class Target < T::Struct
      const :repo, String
      const :public, T::Boolean
    end

    # Any workflow against a public repo: an approved fork PR's YAML could
    # land on the runner (plans#5 Gap 1). Reported by the role, never
    # accepted as a reach.
    class ExposedError < RuntimeError; end

    sig { returns(T.any(Symbol, T::Set[String])) }
    attr_reader :repos

    sig { returns(T.any(Symbol, T::Set[String])) }
    attr_reader :workflows

    sig { returns(T::Set[String]) }
    attr_reader :labels

    # @param repos [Symbol, Set<String>] ALL, or the repos that may send jobs
    # @param workflows [Symbol, Set<String>] ANY, or the pinned workflows
    # @param labels [Set<String>] the labels a job must ask for
    sig { params(repos: T.any(Symbol, T::Set[String]), workflows: T.any(Symbol, T::Set[String]), labels: T::Set[String]).void }
    def initialize(repos:, workflows:, labels:)
      @repos = repos
      @workflows = workflows
      @labels = labels
    end

    # Whether only named workflows may use the runner.
    sig { returns(T::Boolean) }
    def pinned?
      @workflows != ANY
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@repos, @workflows, @labels]
    end
  end
end
