# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/cli/referenced_role_loader"
require "dev/deps/lockfile"
require "dev/lifecycle/project_version"
require "dev/runner_role"
require "dev/runner_role_aliases"
require "dev/runner_setup"
require "dev/runner_status"
require "dev/ui"

module Dev
  module Cli
    module Builtins
      # `dev runner status` — inspect-only: this machine's discovered runner
      # enrollments and their contract facts (see Dev::RunnerStatus). Needs no
      # project (the machine view), but reports the container contract when
      # run inside a project that declares a build container, and holds the
      # slots of the roles that project's dev.yml declares — or references
      # from another project, read there at the version the lock pins —
      # against those roles. `--check` is
      # the host's posture alone, GitHub not asked, exiting 1 on any red
      # fact — what a job runs after `dev up`. A leaf of the `runner` group
      # (RunnerRegisterCommand and RunnerUnregisterCommand are the others).
      class RunnerStatusCommand < BuiltinCommand
        extend T::Sig

        CHECK_FLAG = "--check"

        # Builds the status inspector over the context's Ui; injected for tests.
        StatusFactory = T.type_alias do
          T.proc.params(
            container_required: T::Boolean,
            project_root: T.nilable(Pathname),
            entries: T::Hash[String, Dev::RunnerRole::Entry],
            ui: Dev::Ui,
          ).returns(Dev::RunnerStatus)
        end

        # Resolves a reference to the role it names (over the checkout's lock, closed in).
        ReferenceResolver = T.type_alias { T.proc.params(reference: Dev::RunnerRole::Reference).returns(Dev::RunnerRole) }

        # @param referenced_role_loader [ReferencedRoleLoader] reads a referenced role's declaration from its repo
        # @param runner_status_factory [StatusFactory]
        sig { params(referenced_role_loader: ReferencedRoleLoader, runner_status_factory: StatusFactory).void }
        def initialize(referenced_role_loader: ReferencedRoleLoader.new, runner_status_factory: ->(container_required, project_root, entries, ui) {
          # The lock is what the host identity's reach is checked over, what a
          # referenced role is read at, and the checkout's repo is whose access
          # to each org scope's slots is reported and what its declared roles
          # bind to; none of it outside a checkout (an unresolvable checkout is
          # no repo).
          pins = project_root ? Dev::Deps::Lockfile.new(dir: project_root).read : []
          repo = project_root ? self.class.current_repo : nil
          resolve = ->(reference) { referenced_role_loader.load(reference, pins) }
          roles = self.class.roles_at_hand(entries, project_root: project_root, repo: repo, resolve: resolve)
          Dev::RunnerStatus.new(container_required:, pins:, repo:, roles:, ui:)
        })
          super()
          @runner_status_factory = runner_status_factory
        end

        class << self
          extend T::Sig

          # The checkout's repo as GitHub spells it, or nil when gh cannot say
          # (status is inspect-only: an unresolvable checkout is not an error).
          #
          # @return [String, nil]
          sig { returns(T.nilable(String)) }
          def current_repo
            Dev::RunnerSetup.current_repo
          rescue Dev::RunnerSetup::Error
            nil
          end

          # The roles status holds this host's slots against: the one-release
          # aliases, the checkout's declarations bound to its repo and its
          # series, and the roles its references name, resolved as the caller
          # says (read from their declaring repos at the lock's versions);
          # only when the checkout resolves to a repo, since a declared
          # role's pins are spelled with it.
          #
          # @param entries [Hash{String => Dev::RunnerRole::Entry}] the checkout's dev.yml roles, declared or referenced
          # @param project_root [Pathname, nil] the checkout; nil outside one
          # @param repo [String, nil] the checkout's "owner/repo"; nil when unresolvable
          # @param resolve [Proc] the role a reference names
          # @return [Hash{String => Dev::RunnerRole}]
          # @raise [Dev::RunnerRole::DeclarationError] a declaration pins workflows and the checkout keeps no semver VERSION
          sig do
            params(
              entries: T::Hash[String, Dev::RunnerRole::Entry], project_root: T.nilable(Pathname), repo: T.nilable(String),
              resolve: ReferenceResolver,
            ).returns(T::Hash[String, Dev::RunnerRole])
          end
          def roles_at_hand(entries, project_root:, repo:, resolve:)
            return Dev::RunnerRoleAliases::ALL if project_root.nil? || repo.nil?

            version = Dev::Lifecycle::ProjectVersion.declared(project_root)
            bound = entries.transform_values do |entry|
              case entry
              when Dev::RunnerRole::Declaration then entry.bind(repo: repo, version: version)
              else resolve.call(entry)
              end
            end
            Dev::RunnerRoleAliases::ALL.merge(bound)
          end
        end

        # The summary line, then what `--check` is for.
        sig { override.returns(String) }
        def desc
          <<~DESC
            Inspect this host's runner enrollments and their contract facts

            The machine's view, framed by subject: the host, then one frame per role
            family — each slot's reach, online state and labels against what its role
            expects — then the posture line. Nothing is recorded; every fact is
            re-derived from the host and GitHub each time, and the remedy is named
            on each red line (most: re-run `dev runner register`).

            In a checkout, the roles its dev.yml declares (runner_roles:) are the
            ones a slot is held against — and the roles it references from another
            project (`agent: { from: d3mlabs/ai-flow }`), read from that project's
            dev.yml at the version this checkout's lock pins, so this repo's lane is
            reported under the referenced role. A slot of a role declared elsewhere
            and referenced nowhere is known by its runner group, its reach shown
            but not judged.

            A slot still carrying the job-started hook dev 0.9.x installed (its .env
            keys, its script) is a finding: hosts run what the checkout's lock says,
            and the next `dev runner register` removes the hook.

            #{CHECK_FLAG} inspects the host's posture alone — the runner user and its login,
            the toolchain, each job identity (its user, group memberships, sudoers
            edge, data root, brew locks), the WSL runner host, host tooling — and exits 1
            when any fact is red. GitHub is not asked: the family facts need the org
            token and are the human's run, and a referenced role (read from its
            declaring repo) is left out. Which roles are enrolled is read from each
            enrollment's own record, so it runs in every job on the job's identity;
            a host whose posture is behind the running dev's contract goes red in the
            job's log. Posture stays register's to converge: a job inspects it.
          DESC
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Environment
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [
            Cli::Flag.new(CHECK_FLAG, desc: "the host's posture alone, GitHub not asked: the host frame and the posture line, exit 1 when any fact is red — for every job, on its own identity"),
          ]
        end

        # The full report, or with `--check` the host's posture alone
        # (Dev::RunnerStatus#check raises on drift; the boundary exits 1).
        # `--check` asks GitHub nothing, so a referenced role — read from
        # its declaring repo — is not among the roles it holds slots against.
        #
        # @raise [Dev::RunnerStatus::PostureDriftError] `--check`, with a red fact
        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          project = context.project
          check = args.flag?(CHECK_FLAG)
          entries = project&.runner_roles || {}
          entries = entries.select { |_name, entry| entry.is_a?(Dev::RunnerRole::Declaration) } if check
          status = @runner_status_factory.call(
            project&.project_images&.containerized? || false,
            project&.root,
            entries,
            context.ui,
          )
          check ? status.check : status.report
        end
      end
    end
  end
end
