# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "time"
require "tmpdir"
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
      # `dev release [<version>|major|minor|patch]`: cut a release and stop
      # (dev#192, K4) — no word is the patch bump of the version in source
      # (dev#525). The
      # cut is lifted from dev's `bin/release.rb`: a clean tree, a bump
      # commit when the project keeps its version in source, the tag, the
      # push — resumable, so a retry whose cut already landed (HEAD tagged)
      # finishes the release instead of cutting a second one. Then each
      # release build (`release.targets`, or every build of every
      # packageable target under `release: {}`) is packaged **at the tag** —
      # `package` run as itself per build, so each dispatches by its own
      # environment and the make-like rule applies (a bump commit makes
      # every earlier artifact stale by construction, which is why the cut
      # comes first) — and the archives are attached to the GitHub release
      # as `<build>-<version>.<ext>` with `release.json` beside them.
      # **Nothing is deployed**: distribution is `deploy <channel> --release
      # <version>` per channel (dev#425), a week later from the same bytes
      # if need be.
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
      # never proceeds silently or hangs (dev#514). The verb orchestrates
      # from wherever it was invoked (K10), so its own dispatch is native
      # and each `package` resolves its own. The seam is the cut and the
      # push, one step each under a `Cutting` frame, then `package` per
      # release build in its own frame, each artifact read back from the
      # store and checked current at the tag's commit — the project's
      # builders and packagers run inside it, so a failure there leaves the
      # tag pushed and the release uncreated for the retry to resume.
      # `after`, under a `Publishing` frame, gathers the assets under their
      # release names (ReleaseAssets), writes `release.json`
      # (Manifest::Release: the tag, its commit, the archives with their
      # build ids), creates the GitHub release when missing and uploads,
      # replacing any asset a failed run half-attached; then the epilogue
      # and the split's hint — nothing deployed, `deploy <channel>
      # --release` ships it. The artifacts cross from the seam to `after`
      # through the env: the template's one channel between the stages.
      class ReleaseCommand < LifecycleCommand
        extend T::Sig

        # `release` takes one word — a version or a bump — or none; a bump
        # needs a `VERSION` to bump from.
        class VersionArgumentError < ArgumentError; end

        # A release build's artifact is not in this machine's store at the
        # tag's commit after `package` ran — it was packaged elsewhere, or
        # the tree moved under the cut.
        class ArtifactNotAtTagError < RuntimeError; end

        # `after` ran before the seam packaged the builds — a wiring bug.
        class NothingPackagedError < StandardError; end

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

        # What `before` resolves; the seam fills `artifacts` for `after`.
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

          # @return [Array<Lifecycle::Artifact>, nil] what the seam packaged
          sig { returns(T.nilable(T::Array[Lifecycle::Artifact])) }
          attr_accessor :artifacts

          sig { params(tag: Lifecycle::ReleaseTag, plan: Lifecycle::ReleaseCut::Plan, builds: T::Array[Lifecycle::Build]).void }
          def initialize(tag:, plan:, builds:)
            @tag = tag
            @plan = plan
            @builds = builds
            @artifacts = T.let(nil, T.nilable(T::Array[Lifecycle::Artifact]))
          end

          # @return [Array<Lifecycle::Artifact>]
          # @raise [NothingPackagedError]
          sig { returns(T::Array[Lifecycle::Artifact]) }
          def artifacts!
            @artifacts || raise(NothingPackagedError, "release #{@tag}: `after` ran before the seam packaged the builds")
          end
        end

        Env = type_member { { fixed: ReleaseEnv } }

        # @param release [Lifecycle::ReleaseBuilds] what a release contains
        # @param cut [Lifecycle::ReleaseCut] the git half, over the checkout
        # @param package [PackageCommand] the verb run per release build
        # @param store [Lifecycle::Store] where `package` leaves the artifacts
        # @param releases [Lifecycle::GithubReleases] the release archive on the forge
        # @param listing [BuildListing] what the usage lists
        # @param executor [LifecycleExecutor] runs `package` as itself
        # @param clock [Proc] the manifest's instant (injectable for tests)
        sig do
          params(
            release: Lifecycle::ReleaseBuilds,
            cut: Lifecycle::ReleaseCut,
            package: PackageCommand,
            store: Lifecycle::Store,
            releases: Lifecycle::GithubReleases,
            listing: BuildListing,
            executor: LifecycleExecutor,
            clock: T.proc.returns(Time),
          ).void
        end
        def initialize(release:, cut:, package:, store:, releases:, listing:, executor: LifecycleExecutor.new, clock: -> { Time.now })
          super()
          @release = release
          @cut = cut
          @package = package
          @store = store
          @releases = releases
          @listing = listing
          @executor = executor
          @clock = clock
        end

        sig { override.returns(String) }
        def desc
          "Cut a release: tag, package the release builds at the tag, attach them to the GitHub release (release [<version>|major|minor|patch])\n" \
            "Bumps VERSION when the project keeps one — the patch when no version is given; a retry resumes a cut that landed. Deploys nothing."
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
          # and each `package` it runs resolves its own dispatch (K10) — so
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
            at_tag = Lifecycle::GitState.read(context.project!.root)
            # `package` spawns the builder with the terminal (its output,
            # its progress bars): a step, never a spin.
            env.artifacts = env.builds.map { |build| ui.step("Packaging #{build}") { package(build, at_tag:, context:) } }
          end
        end

        sig { override.params(env: ReleaseEnv, context: ExecutionContext).void }
        def after(env, context:)
          ui = context.ui
          artifacts = env.artifacts!
          sha = @cut.sha(env.tag)
          Dir.mktmpdir("dev-release-") do |tmp|
            dir = Pathname(tmp)
            gathered = artifacts.map { |artifact| Lifecycle::ReleaseAssets.new(dir:).gather(artifact, tag: env.tag) }
            manifest = Lifecycle::Manifest::Release.new(
              stamp: Lifecycle::Manifest::Stamp.now(now: @clock.call), tag: env.tag.name, sha:, archives: gathered.map(&:archive),
            )
            url = ui.frame("Publishing #{env.tag}") do
              ui.spin("Writing #{manifest.file_name}") { manifest.write(dir) }
              page = find_or_create(env, ui:)
              files = gathered.flat_map(&:files) + [dir / manifest.file_name]
              ui.spin("Attaching #{files.map { |file| file.basename.to_s }.join(", ")}") { @releases.upload(env.tag, files) }
              page
            end
            report(env, sha, url, manifest, ui:)
          end
        end

        private

        # The version to release: the one word given when it is a version;
        # the next of the version in source when it is a bump word, or when
        # nothing is given (the patch — a routine release, dev#525).
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
          archives = env.builds.size
          [
            plan.resuming || bump.nil? ? nil : "Bump #{Lifecycle::ProjectVersion::FILE_NAME} #{bump.from} → #{bump.to}",
            plan.resuming ? nil : "Tag #{plan.tag}",
            "Push #{plan.branch} + tag #{plan.tag} to #{Lifecycle::ReleaseCut::REMOTE}",
            "Package #{env.builds.map(&:name).join(", ")} at the tag",
            "Create GitHub release #{plan.tag} and attach #{archives} archive#{"s" unless archives == 1} + #{Lifecycle::Manifest::Release::FILE_NAME}",
          ].compact
        end

        # The GitHub release: the one a failed run already created (a
        # resume attaches to it), else a new one with the plan's notes.
        #
        # @param env [ReleaseEnv]
        # @param ui [Ui]
        # @return [URI] the release's page
        sig { params(env: ReleaseEnv, ui: Ui).returns(URI::Generic) }
        def find_or_create(env, ui:)
          found = @releases.find(env.tag)
          if found
            ui.note("{{v}} GitHub release #{env.tag} exists — attaching to it")
            return found
          end

          ui.spin("Creating GitHub release #{env.tag}") { @releases.create(env.tag, title: env.tag.name, notes: env.plan.notes) }
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

        # `package` as itself for one release build, then its artifact from
        # the store, which must be the tag's.
        #
        # @param build [Lifecycle::Build]
        # @param at_tag [Lifecycle::GitState] the tree after the cut
        # @param context [ExecutionContext]
        # @return [Lifecycle::Artifact]
        # @raise [ArtifactNotAtTagError]
        sig { params(build: Lifecycle::Build, at_tag: Lifecycle::GitState, context: ExecutionContext).returns(Lifecycle::Artifact) }
        def package(build, at_tag:, context:)
          @executor.execute(@package, args: Cli::ParsedArgs.new(words: [build.name], positionals: [build.name]), context:)
          artifact = @store.artifact(build)
          return artifact if artifact&.current?(at_tag)

          raise ArtifactNotAtTagError,
            "#{build} is not in this machine's store at #{at_tag.sha} after packaging — " \
              "#{artifact ? "the store holds #{artifact.manifest.build_id}" : "it was packaged elsewhere"}; a release attaches what was packaged here"
        end

        # The epilogue: what was released from where, each archive, and the
        # split's hint — `release` deploys nothing (ADR-0010).
        #
        # @param env [ReleaseEnv]
        # @param sha [String] the tag's commit
        # @param url [URI] the release's page
        # @param manifest [Lifecycle::Manifest::Release]
        # @param ui [Ui]
        # @return [void]
        sig { params(env: ReleaseEnv, sha: String, url: URI::Generic, manifest: Lifecycle::Manifest::Release, ui: Ui).void }
        def report(env, sha, url, manifest, ui:)
          ui.note("{{v}} {{bold:#{env.tag} released!}} (#{sha[0, Lifecycle::GitState::SHORT_SHA_LENGTH]}, from #{env.plan.branch}) → #{url}")
          manifest.archives.each { |archive| ui.note("  #{archive.name} (#{archive.build_id})") }
          ui.note("Nothing deployed — ship it: dev deploy <channel> --release #{env.tag.version}")
        end
      end
    end
  end
end
