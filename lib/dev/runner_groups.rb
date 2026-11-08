# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/runner_group_contract"
require "dev/runner_registry"

module Dev
  # An org's runner groups, converged to their contracts (dev#470): the
  # group a contract names exists with the access it obliges, the slots
  # of a host sit in it, and the repos whose checkouts register ran in
  # may use it. Every fact is read from GitHub and written back only when
  # it differs (plans#26: inspected, never recorded).
  #
  # One rule holds across every group, owned or named, and lives here
  # because GitHub has no setting for it: **a public repository may only
  # use a runner group restricted to workflows** (plans#5 Gap 1 — an
  # approved fork PR's YAML saying `runs-on: self-hosted` must find no
  # runner). Admitting a public repo to an unpinned group is refused,
  # whatever flags asked for it.
  class RunnerGroups
    extend T::Sig

    # A RuntimeError so the CLI boundary prints the message and exits 1.
    class Error < RuntimeError; end

    # A named group (`--group`) the org does not have — groups a human
    # owns are made in the org's settings, never by dev.
    class NoSuchGroupError < Error; end

    # A public repository asked into a group that is not restricted to
    # workflows (plans#5 H3).
    class UnpinnedGroupError < Error; end

    # @param registry [#group, #create_group!, #update_group!, #group_repositories,
    #   #select_group_repositories!, #place_in_group!, #group_of, #repository]
    # @param out [IO, StringIO]
    sig { params(registry: T.untyped, out: T.any(IO, StringIO)).void }
    def initialize(registry: RunnerRegistry.new, out: $stdout)
      @registry = registry
      @out = out
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
    # @return [Dev::RunnerRegistry::Group]
    # @raise [NoSuchGroupError] a named group the org lacks
    sig { params(contract: RunnerGroupContract, org: String).returns(RunnerRegistry::Group) }
    def converge!(contract, org:)
      group = @registry.group(org: org, name: contract.name)
      unless contract.owned?
        return group if group

        raise NoSuchGroupError,
          "#{org} has no runner group named '#{contract.name}' — create it under the org's Actions settings (Runner groups), then re-run"
      end

      if group.nil?
        @out.puts ">>> Creating runner group '#{contract.name}' at #{org}#{contract.open? ? " (open to every repo)" : ""}, pinned to #{contract.workflows.join(", ")} ..."
        return @registry.create_group!(org: org, name: contract.name, visibility: contract.visibility, allows_public_repositories: contract.open?,
          selected_workflows: contract.workflows)
      end

      drift = contract.drift(group)
      return group if drift.empty?

      # Visibility is named only when it must flip: a PATCH naming it
      # clears the group's selected repositories (plans#5 H3), and a group
      # that was open to all has none to lose.
      @out.puts ">>> Runner group '#{contract.name}' drifted (#{drift.join("; ")}) — re-converging ..."
      flip = group.visibility == contract.visibility ? nil : contract.visibility
      @registry.update_group!(org: org, group_id: group.id, visibility: flip, selected_workflows: contract.workflows)
    end

    # Put a runner in the group when it sits elsewhere (config.sh places
    # only a fresh registration).
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param runner [Dev::RunnerRegistry::Runner]
    # @param org [String]
    sig { params(group: RunnerRegistry::Group, runner: RunnerRegistry::Runner, org: String).void }
    def place!(group, runner, org:)
      current = @registry.group_of(org: org, runner_id: runner.id)
      return if current&.id == group.id

      @out.puts ">>> Moving runner #{runner.id} into group '#{group.name}'#{current ? " from '#{current.name}'" : ""} ..."
      @registry.place_in_group!(org: org, group_id: group.id, runner_id: runner.id)
    end

    # Let a repo use the group: nothing when the group is open to all
    # repos or already selects it; otherwise the public-repo rule, the
    # public flag when the repo needs it, and the selection written whole.
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param repo [String] "owner/repo"
    # @param org [String]
    # @raise [UnpinnedGroupError] a public repo into an unrestricted group
    sig { params(group: RunnerRegistry::Group, repo: String, org: String).void }
    def admit!(group, repo, org:)
      unless group.selected?
        @out.puts ">>> #{repo} may use group '#{group.name}' (open to every repo at #{org})."
        return
      end

      current = T.let(@registry.group_repositories(org: org, group_id: group.id), T::Array[RunnerRegistry::GroupRepository])
      if current.any? { |selected| selected.full_name.casecmp?(repo) }
        @out.puts ">>> #{repo} may use group '#{group.name}'."
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
          @out.puts ">>> Group '#{group.name}' now allows public repositories (#{repo} is public; pinned to #{group.selected_workflows.join(", ")}) ..."
          @registry.update_group!(org: org, group_id: group.id, allows_public_repositories: true, selected_workflows: group.selected_workflows)
        end
      end

      others = current.map(&:full_name).join(", ")
      @out.puts ">>> #{repo} may use group '#{group.name}' (with #{others.empty? ? "no other repo" : others}) ..."
      @registry.select_group_repositories!(org: org, group_id: group.id, repository_ids: current.map(&:id) + [repository.id])
    end

    # Take a repo out of the group's selection; nothing when it is not
    # there (or the group is open to all, which a selection cannot narrow).
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param repo [String] "owner/repo"
    # @param org [String]
    # @raise [Error] the group is open to every repo
    sig { params(group: RunnerRegistry::Group, repo: String, org: String).void }
    def exclude!(group, repo, org:)
      unless group.selected?
        raise Error,
          "group '#{group.name}' is open to every repo at #{org} — narrow it to selected repositories in the org's settings before hiding it from #{repo}"
      end

      current = @registry.group_repositories(org: org, group_id: group.id)
      kept = current.reject { |selected| selected.full_name.casecmp?(repo) }
      if kept.length == current.length
        @out.puts ">>> #{repo} already cannot use group '#{group.name}'."
        return
      end

      left = kept.map(&:full_name).join(", ")
      @out.puts ">>> #{repo} may no longer use group '#{group.name}' (left: #{left.empty? ? "no repo" : left}) ..."
      @registry.select_group_repositories!(org: org, group_id: group.id, repository_ids: kept.map(&:id))
    end
  end
end
