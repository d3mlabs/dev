# typed: strict
# frozen_string_literal: true

require "pathname"
require "uri"
require "dev/cli/build_listing"
require "dev/cli/command"
require "dev/cli/dispatch"
require "dev/lifecycle"
require "dev/cli/lifecycle_executor"
require_relative "package_command"

module Dev
  module Cli
    module Builtins
      # `dev release [<version>|major|minor|patch]`: cut a release and
      # stop; no word is the patch bump of the version in source. The cut
      # is a clean tree, a bump
      # commit when the project keeps its version in source, the tag, the
      # push — resumable, so a retry whose cut already landed (HEAD tagged)
      # finishes the release instead of cutting a second one — and the
      # GitHub release as a draft. Then each release build
      # (`release.targets`, or every build of every packageable target
      # under `release: {}`) is packaged **at the tag and attached** —
      # `package <build> --attach <version>` run as itself per build, so
      # each dispatches by its own environment and the make-like rule
      # applies (a bump commit makes every earlier artifact stale by
      # construction, which is why the cut comes first) — the archive
      # landing on the draft as `<build>-<version>.<ext>` from the host
      # that packaged it, with the build's entry on the draft's
      # `release.json`. **Nothing is deployed**: distribution is `deploy
      # <channel> --release <version>` per channel, a week later from the
      # same bytes if need be.
      #
      # The verb follows the data: a stage runs where its input is, and
      # only the outcome crosses back. The git state — bump, tag, push, the
      # draft, the publish — is this checkout's and stays here; "package
      # at the tag and attach" is one unit per build that runs wherever
      # the build's placement sends it, and what comes back is the fact
      # that the assets are on the draft, never the bytes. So a release
      # whose build is host-placed elsewhere, or runner-only, cuts from
      # here all the same, and this machine's store is no waypoint.
      #
      # The stage: `before` resolves the version (given, or the next of the
      # one in source — ProjectVersion.next) into the tag and reads the
      # checkout into the cut's plan (ReleaseCut#plan — clean, on a branch,
      # the tag absent or already on HEAD, the bump if any, the base and
      # its drift), shows the plan in a frame — the **base line** first:
      # which branch and commit is being released, how far from the
      # previous tag, and whether the checkout is behind or ahead of
      # origin as last fetched, since the cut never pulls — and asks
      # `Proceed?` unless `--yes`; with no terminal to ask at it refuses,
      # never proceeds silently or hangs. The verb orchestrates
      # from wherever it was invoked, so its own dispatch is native
      # and each `package` resolves its own. The seam is the cut, the
      # push and the draft, one step each under a `Cutting` frame, then
      # `package --attach` per release build in its own step — the
      # project's builders and packagers run inside it, so a failure there
      # leaves the tag pushed and the draft for the retry to resume.
      # `after`, under a `Publishing` frame, reads the draft's ledger back
      # (ReleaseLedger) and checks every release build's entry is on it
      # with its asset and a build id from a clean tree at the tag's
      # commit — the same guarantee the local store check gave, enforced
      # against what the forge holds — completes `release.json`
      # (Manifest::Release: the tag, its commit, the archives in release
      # order) and publishes the draft; then the epilogue and the split's
      # hint — nothing deployed, `deploy <channel> --release` ships it. The
      # release's page crosses from the seam to `after` through the env:
      # the template's one channel between the stages.
      #
      # A release moves no head. On a project deploying through the gh
      # channel the forge's latest designation is that channel's head, so
      # the release is published with `--latest=false` and `deploy gh`
      # designates it. And a head is only safe on a release the forge has
      # frozen: the epilogue warns when the release came out mutable,
      # naming the repository setting that freezes the next one.
      class ReleaseCommand < LifecycleCommand
        extend T::Sig

        # `release` takes one word — a version or a bump — or none; a bump
        # needs a `VERSION` to bump from.
        class VersionArgumentError < ArgumentError; end

        # A release build has no entry on the draft's `release.json`, or
        # its asset is not on the release, after `package --attach` ran —
        # the attach did not land.
        class NotAttachedError < RuntimeError; end

        # A release build's entry on the draft was not packaged from a
        # clean tree at the tag's commit — it was attached from another
        # tree, or the tree moved under the cut.
        class ArtifactNotAtTagError < RuntimeError; end

        # `after` ran before the seam found or created the GitHub release —
        # a wiring bug.
        class ReleaseNotCreatedError < StandardError; end

        # The operator answered no at the confirm: nothing was cut.
        class DeclinedError < RuntimeError; end

        # No terminal to confirm at and no `--yes`: a release is never cut
        # on an assumed yes.
        class NoTerminalError < RuntimeError; end

        NAME = "release"
        LISTING_HEADING = "Release builds"
        YES_FLAG = "--yes"
        FLAGS = T.let(
          [Cli::Flag.new(YES_FLAG, desc: "skip the confirmation (required where there is no terminal to ask at)")].freeze,
          T::Array[Cli::Flag],
        )
        CONFIRM = "Proceed?"

        # What `before` resolves; the seam fills `release` for `after`.
        class ReleaseEnv
          extend T::Sig

          sig { returns(Lifecycle::ReleaseTag) }
          attr_reader :tag

          # @return [Lifecycle::ReleaseCut::Plan] what the cut will do
          sig { returns(Lifecycle::ReleaseCut::Plan) }
          attr_reader :plan

          # @return [Array<Lifecycle::Build>] the release builds, in order
          sig { returns(T::Array[Lifecycle::Build]) }
          attr_reader :builds

          # @return [Lifecycle::GithubReleases::Found, nil] the GitHub release the seam found or created
          sig { returns(T.nilable(Lifecycle::GithubReleases::Found)) }
          attr_accessor :release

          sig { params(tag: Lifecycle::ReleaseTag, plan: Lifecycle::ReleaseCut::Plan, builds: T::Array[Lifecycle::Build]).void }
          def initialize(tag:, plan:, builds:)
            @tag = tag
            @plan = plan
            @builds = builds
            @release = T.let(nil, T.nilable(Lifecycle::GithubReleases::Found))
          end

          # @return [Lifecycle::GithubReleases::Found]
          # @raise [ReleaseNotCreatedError]
          sig { returns(Lifecycle::GithubReleases::Found) }
          def release!
            @release || raise(ReleaseNotCreatedError, "release #{@tag}: `after` ran before the seam found or created the GitHub release")
          end
        end

        Env = type_member { { fixed: ReleaseEnv } }

        # @param release [Lifecycle::ReleaseBuilds] what a release contains
        # @param cut [Lifecycle::ReleaseCut] the git half, over the checkout
        # @param package [PackageCommand] the verb run per release build, with `--attach`
        # @param releases [Lifecycle::GithubReleases] the release archive on the forge
        # @param ledger [Lifecycle::ReleaseLedger] the draft's `release.json`, where each attach records
        # @param listing [BuildListing] what the usage lists
        # @param designates_latest [Boolean] whether the forge may designate
        #   the release its latest; false on a project with a gh channel,
        #   whose head the designation is
        # @param executor [LifecycleExecutor] runs `package` as itself
        sig do
          params(
            release: Lifecycle::ReleaseBuilds,
            cut: Lifecycle::ReleaseCut,
            package: PackageCommand,
            releases: Lifecycle::GithubReleases,
            ledger: Lifecycle::ReleaseLedger,
            listing: BuildListing,
            designates_latest: T::Boolean,
            executor: LifecycleExecutor,
          ).void
        end
        def initialize(release:, cut:, package:, releases:, ledger:, listing:, designates_latest: true, executor: LifecycleExecutor.new)
          super()
          @release = release
          @cut = cut
          @package = package
          @releases = releases
          @ledger = ledger
          @listing = listing
          @designates_latest = designates_latest
          @executor = executor
        end

        sig { override.returns(String) }
        def desc
          "Cut a release: tag, package the release builds at the tag, attach them to the GitHub release\n" \
            "Bumps VERSION when the project keeps one — the patch when no version is given; a retry resumes a cut that landed. Deploys nothing."
        end

        # One word: a version, or the part of VERSION to bump.
        sig { override.returns(T.nilable(String)) }
        def synopsis
          "[<version>|major|minor|patch]"
        end

        sig { override.returns(T::Array[Cli::Positional]) }
        def positionals
          [
            Cli::Positional.new(
              "version", optional: true,
              desc: "the version to cut, or the part of VERSION to bump — major, minor or patch (default: patch)",
            ),
          ]
        end

        sig { override.returns(T.nilable(Listing)) }
        def listing
          @listing.listing_of(@release.builds, heading: LISTING_HEADING)
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          FLAGS
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[ReleaseEnv]) }
        def before(args:, context:)
          tag = Lifecycle::ReleaseTag.new(version(args, root: context.project!.root))
          env = ReleaseEnv.new(tag:, plan: @cut.plan(tag), builds: @release.builds)
          show_plan(env, ui: context.ui)
          confirm!(args, ui: context.ui)
          # The verb orchestrates from here: the cut is this checkout's git,
          # and each `package` it runs resolves its own dispatch — so
          # the dispatch is native and the invocation it is handed is never
          # spoken to a host.
          Dispatch::Native.new.dispatch(Lifecycle::VerbInvocation.new(words: [NAME, tag.version])) { env }
        end

        sig { override.params(env: ReleaseEnv, context: ExecutionContext).void }
        def seam(env, context:)
          ui = context.ui
          plan = env.plan
          ui.frame(plan.resuming ? "Resuming #{plan.tag}" : "Cutting #{plan.tag}") do
            bump = plan.bump
            ui.spin("Bumping #{Lifecycle::ProjectVersion::FILE_NAME} #{bump.from} → #{bump.to}") { @cut.bump!(plan) } if bump
            ui.spin("Tagging #{plan.tag}") { @cut.tag!(plan) } unless plan.resuming
            ui.spin("Pushing #{plan.branch} + tag #{plan.tag} to #{Lifecycle::ReleaseCut::REMOTE}") { @cut.push!(plan) }
            # The draft precedes packaging: each `package --attach` lands on it.
            env.release = find_or_create(env, ui:)
            # `package` spawns the builder with the terminal (its output,
            # its progress bars): a step, never a spin.
            env.builds.each { |build| ui.step("Packaging #{build} and attaching to #{plan.tag}") { package(build, tag: env.tag, context:) } }
          end
        end

        sig { override.params(env: ReleaseEnv, context: ExecutionContext).void }
        def after(env, context:)
          ui = context.ui
          page = env.release!
          sha = @cut.sha(env.tag)
          manifest = ui.frame("Publishing #{env.tag}") do
            entries = ui.spin("Reading #{Lifecycle::ReleaseLedger::FILE_NAME} from #{env.tag}'s release") { attached_entries(env, sha:) }
            completed = ui.spin("Writing #{Lifecycle::ReleaseLedger::FILE_NAME}") { @ledger.complete(env.tag, sha:, archives: entries) }
            # Last, so the asset list a repository with immutable releases
            # freezes at publish is the complete one (dev#679).
            ui.spin("Publishing GitHub release #{env.tag}") { @releases.publish(env.tag, latest: @designates_latest) } if page.draft
            completed
          end
          report(env, sha, page.url, manifest, facts: @releases.facts(env.tag), ui:)
        end

        private

        # The version to release: the one word given when it is a version;
        # the next of the version in source when it is a bump word, or when
        # nothing is given (the patch — a routine release).
        #
        # @param args [Cli::ParsedArgs]
        # @param root [Pathname] the project root, where `VERSION` is read
        # @return [String]
        # @raise [VersionArgumentError] more than one word; a bump with no `VERSION` to bump from
        # @raise [Lifecycle::ProjectVersion::NotSemverError] a bump of a version that is not three numbers
        sig { params(args: Cli::ParsedArgs, root: Pathname).returns(String) }
        def version(args, root:)
          words = args.positionals
          if words.length > 1
            raise VersionArgumentError,
              "release takes one version or bump (`dev release`, `dev release 1.2.0`, `dev release minor`), got #{words.map(&:inspect).join(", ")}"
          end

          word = words.first
          part = word.nil? ? Lifecycle::ProjectVersion::Part::Patch : Lifecycle::ProjectVersion::Part.try_deserialize(word)
          return T.must(word) if part.nil?

          current = Lifecycle::ProjectVersion.declared(root)
          raise VersionArgumentError, "release has no #{Lifecycle::ProjectVersion::FILE_NAME} to bump from — give the version (`dev release 1.2.0`)" if current.nil?

          Lifecycle::ProjectVersion.next(current, part)
        end

        # The plan frame: what is being released from where, the notes,
        # and the numbered steps the verb is about to take.
        #
        # @param env [ReleaseEnv]
        # @param ui [Ui]
        # @return [void]
        sig { params(env: ReleaseEnv, ui: Ui).void }
        def show_plan(env, ui:)
          plan = env.plan
          ui.frame(plan_title(plan)) do
            ui.note("{{bold:Base:}} #{base_line(plan)}")
            ui.note("{{bold:Notes:}}")
            plan.notes.lines(chomp: true).each { |line| ui.note("  #{line}") }
            ui.note("{{bold:Steps:}}")
            steps(env).each_with_index { |step, index| ui.note("  #{index + 1}. #{step}") }
          end
        end

        # @param plan [Lifecycle::ReleaseCut::Plan]
        # @return [String]
        sig { params(plan: Lifecycle::ReleaseCut::Plan).returns(String) }
        def plan_title(plan)
          return "Resuming #{plan.tag}" if plan.resuming

          bump = plan.bump
          bump ? "Release: #{bump.from} → #{bump.to}" : "Release: #{plan.tag}"
        end

        # Which checkout is being released: branch, commit, distance from
        # the previous tag, and the drift from origin as last fetched — the
        # cut never pulls, so a stale checkout is reported here, for the
        # operator to weigh at the confirm.
        #
        # @param plan [Lifecycle::ReleaseCut::Plan]
        # @return [String]
        sig { params(plan: Lifecycle::ReleaseCut::Plan).returns(String) }
        def base_line(plan)
          since =
            if plan.resuming then "HEAD already tagged, nothing to cut"
            elsif plan.previous.nil? then "first release, no previous tag"
            else "#{plan.commits.size} commit#{"s" unless plan.commits.one?} since #{plan.previous}"
            end
          "#{plan.branch} @ #{plan.sha[0, Lifecycle::GitState::SHORT_SHA_LENGTH]} — #{since} (#{plan.drift})"
        end

        # @param env [ReleaseEnv]
        # @return [Array<String>] the steps, in the imperative
        sig { params(env: ReleaseEnv).returns(T::Array[String]) }
        def steps(env)
          plan = env.plan
          bump = plan.bump
          [
            plan.resuming || bump.nil? ? nil : "Bump #{Lifecycle::ProjectVersion::FILE_NAME} #{bump.from} → #{bump.to}",
            plan.resuming ? nil : "Tag #{plan.tag}",
            "Push #{plan.branch} + tag #{plan.tag} to #{Lifecycle::ReleaseCut::REMOTE}",
            "Create GitHub release #{plan.tag} as a draft",
            "Package #{env.builds.map(&:name).join(", ")} at the tag and attach, each from the host that packages it",
            "Publish GitHub release #{plan.tag} with #{Lifecycle::ReleaseLedger::FILE_NAME}" \
              "#{" (not latest: `deploy gh` designates it)" unless @designates_latest}",
          ].compact
        end

        # The tag's release: the one the forge holds (a draft a failed run
        # left, or one already published — a mutable repository still takes
        # assets onto it), or a fresh draft with the plan's notes.
        #
        # @param env [ReleaseEnv]
        # @param ui [Ui]
        # @return [GithubReleases::Found] the release's page and whether it is a draft to publish
        sig { params(env: ReleaseEnv, ui: Ui).returns(Lifecycle::GithubReleases::Found) }
        def find_or_create(env, ui:)
          found = @releases.find(env.tag)
          if found
            ui.note("{{v}} GitHub release #{env.tag} exists#{" as a draft" if found.draft} — attaching to it#{" and publishing" if found.draft}")
            return found
          end

          page = ui.spin("Creating GitHub release #{env.tag}") do
            @releases.create(env.tag, title: env.tag.name, notes: env.plan.notes)
          end
          Lifecycle::GithubReleases::Found.new(url: page, draft: true)
        end

        # `--yes`, or the terminal's answer. No terminal is a refusal: a
        # release is never cut on an assumed yes, and never hangs on a
        # prompt nobody will see (ai-flow, the runner).
        #
        # @param args [Cli::ParsedArgs]
        # @param ui [Ui]
        # @return [void]
        # @raise [DeclinedError]
        # @raise [NoTerminalError]
        sig { params(args: Cli::ParsedArgs, ui: Ui).void }
        def confirm!(args, ui:)
          return if args.flag?(YES_FLAG)

          case ui.confirm(CONFIRM)
          when true then nil
          when false then raise DeclinedError, "aborted — nothing cut"
          else raise NoTerminalError, "no terminal to confirm at — pass #{YES_FLAG}"
          end
        end

        # `package <build> --attach <version>` as itself for one release
        # build: it packages at the tag and attaches from wherever its
        # placement runs it; what it left on the forge is `after`'s to read.
        #
        # @param build [Lifecycle::Build]
        # @param tag [Lifecycle::ReleaseTag]
        # @param context [ExecutionContext]
        # @return [void]
        sig { params(build: Lifecycle::Build, tag: Lifecycle::ReleaseTag, context: ExecutionContext).void }
        def package(build, tag:, context:)
          attach = PackageCommand::ATTACH_FLAG
          args = Cli::ParsedArgs.new(words: [build.name, attach, tag.version], positionals: [build.name], values: { attach => [tag.version] })
          @executor.execute(@package, args:, context:)
        end

        # Every release build's entry on the draft's ledger, in release
        # order, each checked as the local store check once was: the entry
        # is on, its asset is on the release, and its build id was stamped
        # from a clean tree at the tag's commit.
        #
        # @param env [ReleaseEnv]
        # @param sha [String] the tag's commit
        # @return [Array<Lifecycle::Manifest::Release::Archive>]
        # @raise [NotAttachedError]
        # @raise [ArtifactNotAtTagError]
        sig { params(env: ReleaseEnv, sha: String).returns(T::Array[Lifecycle::Manifest::Release::Archive]) }
        def attached_entries(env, sha:)
          recorded = @ledger.read(env.tag)&.archives || []
          assets = @releases.asset_names(env.tag)
          at_tag = Lifecycle::GitState.new(sha: sha[0, Lifecycle::GitState::SHORT_SHA_LENGTH], dirty: false)
          env.builds.map do |build|
            entry = recorded.find { |archive| archive.build == build }
            if entry.nil? || !assets.include?(entry.name)
              raise NotAttachedError,
                "#{build} is not attached to #{env.tag}'s release after packaging — " \
                  "#{entry ? "#{entry.name} is on #{Lifecycle::ReleaseLedger::FILE_NAME} but not among the release's assets" : "it has no entry on #{Lifecycle::ReleaseLedger::FILE_NAME}"}"
            end
            unless entry.build_id.from?(at_tag)
              raise ArtifactNotAtTagError,
                "#{build} attached to #{env.tag} as #{entry.build_id}, not from a clean tree at #{at_tag.sha} — a release attaches what was packaged at its tag"
            end

            entry
          end
        end

        # The epilogue: what was released from where, each archive, the
        # warning when the forge left the release mutable, and the split's
        # hint — `release` deploys nothing.
        #
        # @param env [ReleaseEnv]
        # @param sha [String] the tag's commit
        # @param url [URI] the release's page
        # @param manifest [Lifecycle::Manifest::Release]
        # @param facts [Lifecycle::GithubReleases::Facts] the release as the forge holds it
        # @param ui [Ui]
        # @return [void]
        sig do
          params(env: ReleaseEnv, sha: String, url: URI::Generic, manifest: Lifecycle::Manifest::Release, facts: Lifecycle::GithubReleases::Facts, ui: Ui).void
        end
        def report(env, sha, url, manifest, facts:, ui:)
          ui.note("{{v}} {{bold:#{env.tag} released!}} (#{sha[0, Lifecycle::GitState::SHORT_SHA_LENGTH]}, from #{env.plan.branch}) → #{url}")
          manifest.archives.each { |archive| ui.note("  #{archive.name} (#{archive.build_id})") }
          unless facts.immutable
            ui.note(
              "{{!}} #{env.tag}'s release is mutable: its tag and assets can still change, so no head may point at it — " \
                "enable immutable releases on the repository (#{Lifecycle::GithubReleases::IMMUTABLE_RELEASES_SETTING}) before the next release",
            )
          end
          ui.note("Nothing deployed — ship it: dev deploy <channel> --release #{env.tag.version}")
        end
      end
    end
  end
end
