# typed: strict
# frozen_string_literal: true

require "set"
require_relative "value_equality"

module Dev
  # Who may land a job on a runner: from which repos, through which
  # workflows, on which labels. The scope decides who fixes the repos —
  # the repo itself, or a runner group's selection — and only a group can
  # pin the workflows, so reach is a property of the role
  # (RunnerRole#expected_reach).
  class Reach
    extend T::Sig
    include Dev::ValueEquality::Derived

    # Every repository in the org (a group with visibility "all").
    ALL = :all
    # Any workflow at all (no pin — the repo's own workflows, or an
    # unrestricted group).
    ANY = :any

    # The repo a registration is for, and whether it is public.
    class Target < T::Struct
      const :repo, String
      const :public, T::Boolean
    end

    # A runner that any workflow of a public repo could use: an approved
    # fork PR's YAML could land on it. Raised by the role instead of a
    # reach.
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
