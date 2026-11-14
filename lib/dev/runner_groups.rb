# typed: strict
# frozen_string_literal: true

require "dev/runner_group_contract"
require "dev/runner_registry"
require "dev/ui"

module Dev
  # An org's runner groups, converged to their contracts: the
  # group a contract names exists with the access it obliges, the slots
  # of a host sit in it, and the repos whose checkouts register ran in
  # may use it. Every fact is read from GitHub and written back only when
  # it differs (inspected, never recorded).
  #
  # One rule holds across every group, owned or named, and lives here
  # because GitHub has no setting for it: **a public repository may only
  # use a runner group restricted to workflows** (an approved fork PR's
  # YAML saying `runs-on: self-hosted` must find no
  # runner). Admitting a public repo to an unpinned group is refused,
  # whatever flags asked for it.
  #
  # Every verb takes the Ui it speaks through: a write to GitHub is a
  # spin (captured gh, parsed), a fact already so is a note with its
  # glyph, and a group that needs nothing says nothing.
  class RunnerGroups
    extend T::Sig

    # A RuntimeError so the CLI boundary prints the message and exits 1.
    class Error < RuntimeError; end

    # A named group (`--group`) the org does not have — groups a human
    # owns are made in the org's settings, never by dev.
    class NoSuchGroupError < Error; end

    # A public repository asked into a group that is not restricted to
    # workflows.
    class UnpinnedGroupError < Error; end

    # @param registry [#group, #create_group!, #update_group!, #group_repositories,
    #   #select_group_repositories!, #place_in_group!, #group_of, #repository]
    sig { params(registry: T.untyped).void }
    def initialize(registry: RunnerRegistry.new)
      @registry = registry
    end

    # The group a contract names, as GitHub records it once converged: an
    # owned group is created when missing — at the contract's visibility,
    # pinned; a selected group closed to public repos until one is
    # admitted, an open one allowing them from the start (there is no
    # admit step to turn it on, and the pin is the defense) — and
    # re-pinned or re-opened/re-selected when the console drifted; a named
    # group must exist.
    #
    # @param contract [Dev::RunnerGroupContract]
    # @param org [String]
    # @param ui [Ui]
    # @return [Dev::RunnerRegistry::Group]
    # @raise [NoSuchGroupError] a named group the org lacks
    sig { params(contract: RunnerGroupContract, org: String, ui: Ui).returns(RunnerRegistry::Group) }
    def converge!(contract, org:, ui:)
      group = @registry.group(org: org, name: contract.name)
      unless contract.owned?
        return group if group

        raise NoSuchGroupError,
          "#{org} has no runner group named '#{contract.name}' — create it under the org's Actions settings (Runner groups), then re-run"
      end

      if group.nil?
        return ui.spin("Creating runner group '#{contract.name}' at #{org}#{contract.open? ? " (open to every repo)" : ""}, pinned to #{contract.workflows.join(", ")}") do
          @registry.create_group!(org: org, name: contract.name, visibility: contract.visibility, allows_public_repositories: contract.open?,
            selected_workflows: contract.workflows)
        end
      end

      drift = contract.drift(group)
      return group if drift.empty?

      # Visibility is named only when it must flip: a PATCH naming it
      # clears the group's selected repositories, and a group
      # that was open to all has none to lose.
      flip = group.visibility == contract.visibility ? nil : contract.visibility
      ui.spin("Re-converging runner group '#{contract.name}' — drifted: #{drift.join("; ")}") do
        @registry.update_group!(org: org, group_id: group.id, visibility: flip, selected_workflows: contract.workflows)
      end
    end

    # Put a runner in the group when it sits elsewhere (config.sh places
    # only a fresh registration).
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param runner [Dev::RunnerRegistry::Runner]
    # @param org [String]
    # @param ui [Ui]
    sig { params(group: RunnerRegistry::Group, runner: RunnerRegistry::Runner, org: String, ui: Ui).void }
    def place!(group, runner, org:, ui:)
      current = @registry.group_of(org: org, runner_id: runner.id)
      return if current&.id == group.id

      ui.spin("Moving runner #{runner.id} into group '#{group.name}'#{current ? " from '#{current.name}'" : ""}") do
        @registry.place_in_group!(org: org, group_id: group.id, runner_id: runner.id)
      end
    end

    # Let a repo use the group: nothing when the group is open to all
    # repos or already selects it; otherwise the public-repo rule, the
    # public flag when the repo needs it, and the selection written whole.
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param repo [String] "owner/repo"
    # @param org [String]
    # @param ui [Ui]
    # @raise [UnpinnedGroupError] a public repo into an unrestricted group
    sig { params(group: RunnerRegistry::Group, repo: String, org: String, ui: Ui).void }
    def admit!(group, repo, org:, ui:)
      unless group.selected?
        ui.note("{{v}} #{repo} may use group '#{group.name}' (open to every repo at #{org})")
        return
      end

      current = T.let(@registry.group_repositories(org: org, group_id: group.id), T::Array[RunnerRegistry::GroupRepository])
      if current.any? { |selected| selected.full_name.casecmp?(repo) }
        ui.note("{{v}} #{repo} may use group '#{group.name}'")
        return
      end

      repository = @registry.repository(repo)
      if repository.public?
        unless group.pinned?
          raise UnpinnedGroupError,
            "#{repo} is public and group '#{group.name}' is not pinned to any workflow — an approved fork PR's YAML could land " \
              "on these runners (plans#5 H3). Pin the group to the workflows that may use it, or enroll for a private repo."
        end
        unless group.allows_public_repositories
          # The pins ride along: GitHub's PATCH wipes what it does not name.
          ui.spin("Allowing public repositories in group '#{group.name}' (#{repo} is public; pinned to #{group.selected_workflows.join(", ")})") do
            @registry.update_group!(org: org, group_id: group.id, allows_public_repositories: true, selected_workflows: group.selected_workflows)
          end
        end
      end

      others = current.map(&:full_name).join(", ")
      ui.spin("Admitting #{repo} to group '#{group.name}' (with #{others.empty? ? "no other repo" : others})") do
        @registry.select_group_repositories!(org: org, group_id: group.id, repository_ids: current.map(&:id) + [repository.id])
      end
    end

    # Take a repo out of the group's selection; nothing when it is not
    # there (or the group is open to all, which a selection cannot narrow).
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param repo [String] "owner/repo"
    # @param org [String]
    # @param ui [Ui]
    # @raise [Error] the group is open to every repo
    sig { params(group: RunnerRegistry::Group, repo: String, org: String, ui: Ui).void }
    def exclude!(group, repo, org:, ui:)
      unless group.selected?
        raise Error,
          "group '#{group.name}' is open to every repo at #{org} — narrow it to selected repositories in the org's settings before hiding it from #{repo}"
      end

      current = @registry.group_repositories(org: org, group_id: group.id)
      kept = current.reject { |selected| selected.full_name.casecmp?(repo) }
      if kept.length == current.length
        ui.note("{{v}} #{repo} already cannot use group '#{group.name}'")
        return
      end

      left = kept.map(&:full_name).join(", ")
      ui.spin("Excluding #{repo} from group '#{group.name}' (left: #{left.empty? ? "no repo" : left})") do
        @registry.select_group_repositories!(org: org, group_id: group.id, repository_ids: kept.map(&:id))
      end
    end
  end
end
