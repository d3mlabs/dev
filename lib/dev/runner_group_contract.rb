# typed: strict
# frozen_string_literal: true

require "dev/runner_registry"

module Dev
  # What an org runner group should be, as a label contract obliges it
  # (plans#5 H3, dev#470): its name and the workflows pinned as the only
  # ones that may land jobs on it. Labels say what a host can do; the
  # group says who may use it — which repos (its selected repositories,
  # converged from the checkouts register runs in) and which workflows.
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

    sig { returns(String) }
    attr_reader :name

    # `owner/repo/.github/workflows/<file>.yml@<ref>`, GitHub's spelling.
    sig { returns(T::Array[String]) }
    attr_reader :workflows

    # @param name [String]
    # @param workflows [Array<String>] the pins; empty = not dev's to pin
    sig { params(name: String, workflows: T::Array[String]).void }
    def initialize(name:, workflows: [])
      @name = name
      @workflows = workflows
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
      drift << "visibility is '#{group.visibility}', not 'selected'" unless group.selected?
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

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      other.is_a?(RunnerGroupContract) && @name == other.name && @workflows == other.workflows
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash
      [@name, @workflows].hash
    end
  end
end
