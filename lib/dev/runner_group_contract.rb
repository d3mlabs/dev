# typed: strict
# frozen_string_literal: true

require "dev/runner_registry"
require_relative "value_equality"

module Dev
  # What an org runner group should be, as a label contract obliges
  # it: its name and the workflows pinned as the only
  # ones that may land jobs on it. Labels say what a host can do; the
  # group says who may use it — which repos and which workflows.
  #
  # Which repos is the contract's **visibility**. `selected`
  # — the default — means the repos register was run for, and that
  # selection is load-bearing: a repo's concurrency on a host is the
  # runners it can see, so the build slots' group admits a
  # repo deliberately or not at all. `all` means every repo in the org:
  # the shape for a pool with nothing to gate (the orchestrator's — API
  # calls and sleep — which a plan in any adopter may need), where a
  # selection would only be a list to forget a new adopter from. The
  # workflow pin, not the selection, is what keeps a fork's YAML off the
  # host either way.
  #
  # A contract with pins is **owned**: dev creates the group when it is
  # missing and re-converges its workflow access and visibility when the
  # console drifted — the pin is the structural defense against a fork's
  # arbitrary YAML reaching a self-hosted box, and it is an invariant of
  # the labels, not a setting someone remembers. A contract without pins
  # names a group a human made (`--group`); dev places slots in it and
  # admits repos to it, but what it pins is theirs.
  class RunnerGroupContract
    extend T::Sig
    include Dev::ValueEquality::Derived

    sig { returns(String) }
    attr_reader :name

    # `owner/repo/.github/workflows/<file>.yml@<ref>`, GitHub's spelling.
    sig { returns(T::Array[String]) }
    attr_reader :workflows

    # GitHub's spelling: "selected" (the repos register admits) or "all".
    sig { returns(String) }
    attr_reader :visibility

    # @param name [String]
    # @param workflows [Array<String>] the pins; empty = not dev's to pin
    # @param visibility [String] "selected" (default) or "all"
    sig { params(name: String, workflows: T::Array[String], visibility: String).void }
    def initialize(name:, workflows: [], visibility: "selected")
      @name = name
      @workflows = workflows
      @visibility = visibility
    end

    # Whether every repo in the org may use the group (no selection to converge).
    sig { returns(T::Boolean) }
    def open?
      @visibility == "all"
    end

    # Whether dev owns the group's access (creates it, re-pins it).
    sig { returns(T::Boolean) }
    def owned?
      !@workflows.empty?
    end

    # What a group as GitHub records it has drifted from this contract,
    # one line each; empty when it satisfies it. A named group satisfies
    # its contract by existing.
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @return [Array<String>]
    sig { params(group: RunnerRegistry::Group).returns(T::Array[String]) }
    def drift(group)
      return [] unless owned?

      drift = []
      drift << "visibility is '#{group.visibility}', not '#{@visibility}'" unless group.visibility == @visibility
      unless group.restricted_to_workflows && group.selected_workflows.sort == @workflows.sort
        drift << if !group.restricted_to_workflows
          "not restricted to workflows"
        elsif group.selected_workflows.empty?
          "pinned to nothing — no workflow may use it"
        else
          "pinned to #{group.selected_workflows.join(", ")}"
        end
      end
      drift
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@name, @workflows, @visibility]
    end
  end
end
