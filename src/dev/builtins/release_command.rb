# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "time"
require "tmpdir"
require "uri"
require "dev/build_listing"
require "dev/command"
require "dev/dispatch"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require_relative "package_command"

module Dev
  module Builtins
    # `dev release <version>`: cut a release and stop (dev#192, K4). The
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
    # The stage: `before` consumes the version into the tag and reads the
    # checkout into the cut's plan (ReleaseCut#plan — clean, on a branch,
    # the tag absent or already on HEAD, the bump if any); the verb
    # orchestrates from wherever it was invoked (K10), so its own dispatch
    # is native and each `package` resolves its own. The seam is the cut
    # and the push, then `package` per release build, each artifact read
    # back from the store and checked current at the tag's commit — the
    # project's builders and packagers run inside it, so a failure there
    # leaves the tag pushed and the release uncreated for the retry to
    # resume. `after` gathers the assets under their release names
    # (ReleaseAssets), writes `release.json` (Manifest::Release: the tag,
    # its commit, the archives with their build ids), creates the GitHub
    # release when missing and uploads, replacing any asset a failed run
    # half-attached. The artifacts cross from the seam to `after` through
    # the env: the template's one channel between the stages.
    class ReleaseCommand < LifecycleCommand
      extend T::Sig

      # `release` takes exactly one version.
      class VersionArgumentError < ArgumentError; end

      # A release build's artifact is not in this machine's store at the
      # tag's commit after `package` ran — it was packaged elsewhere, or
      # the tree moved under the cut.
      class ArtifactNotAtTagError < RuntimeError; end

      # `after` ran before the seam packaged the builds — a wiring bug.
      class NothingPackagedError < StandardError; end

      NAME = "release"
      LISTING_HEADING = "Release builds"

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
      # @param out [IO, StringIO]
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
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(release:, cut:, package:, store:, releases:, listing:, executor: LifecycleExecutor.new, clock: -> { Time.now }, out: $stdout)
        super()
        @release = release
        @cut = cut
        @package = package
        @store = store
        @releases = releases
        @listing = listing
        @executor = executor
        @clock = clock
        @out = out
      end

      sig { override.returns(String) }
      def desc
        "Cut a release: tag, package the release builds at the tag, attach them to the GitHub release (release <version>)\n" \
          "Bumps VERSION when the project keeps one; a retry resumes a cut that landed. Deploys nothing."
      end

      sig { override.returns(T.nilable(Listing)) }
      def listing = @listing.listing_of(@release.builds, heading: LISTING_HEADING)

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[ReleaseEnv]) }
      def before(args:, context:)
        _ = context
        tag = Lifecycle::ReleaseTag.new(version(args))
        # The verb orchestrates from here: the cut is this checkout's git,
        # and each `package` it runs resolves its own dispatch (K10) — so
        # the dispatch is native and the invocation it is handed is never
        # spoken to a host.
        Dispatch::Native.new.dispatch(Lifecycle::VerbInvocation.new(words: [NAME, tag.version])) do
          ReleaseEnv.new(tag:, plan: @cut.plan(tag), builds: @release.builds)
        end
      end

      sig { override.params(env: ReleaseEnv, context: ExecutionContext).void }
      def seam(env, context:)
        @out.puts announce(env.plan)
        @cut.cut!(env.plan)
        @cut.push!(env.plan)
        at_tag = Lifecycle::GitState.read(context.project!.root)
        env.artifacts = env.builds.map { |build| package(build, at_tag:, context:) }
      end

      sig { override.params(env: ReleaseEnv, context: ExecutionContext).void }
      def after(env, context:)
        _ = context
        artifacts = env.artifacts!
        sha = @cut.sha(env.tag)
        Dir.mktmpdir("dev-release-") do |tmp|
          dir = Pathname(tmp)
          gathered = artifacts.map { |artifact| Lifecycle::ReleaseAssets.new(dir:).gather(artifact, tag: env.tag) }
          manifest = Lifecycle::Manifest::Release.new(
            stamp: Lifecycle::Manifest::Stamp.now(now: @clock.call), tag: env.tag.name, sha:, archives: gathered.map(&:archive),
          )
          manifest.write(dir)
          url = @releases.find(env.tag) || @releases.create(env.tag, title: env.tag.name, notes: env.plan.notes)
          @releases.upload(env.tag, gathered.flat_map(&:files) + [dir / manifest.file_name])
          report(env, sha, url, manifest)
        end
      end

      private

      # @param args [Cli::ParsedArgs]
      # @return [String] the one positional
      # @raise [VersionArgumentError]
      sig { params(args: Cli::ParsedArgs).returns(String) }
      def version(args)
        return T.must(args.positionals.first) if args.positionals.one?

        raise VersionArgumentError,
          "release takes one version (`dev release 1.2.0`), got #{args.positionals.empty? ? "none" : args.positionals.map(&:inspect).join(", ")}"
      end

      # @param plan [Lifecycle::ReleaseCut::Plan]
      # @return [String] what the cut is about to do
      sig { params(plan: Lifecycle::ReleaseCut::Plan).returns(String) }
      def announce(plan)
        return "resuming #{plan.tag}: HEAD is already tagged — pushing, then packaging at the tag" if plan.resuming

        bump = plan.bump
        steps = [bump ? "bump #{Lifecycle::ProjectVersion::FILE_NAME} #{bump.from} → #{bump.to}" : nil, "tag", "push"].compact
        "cutting #{plan.tag} on #{plan.branch}: #{steps.join(", ")}"
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

      # @param env [ReleaseEnv]
      # @param sha [String] the tag's commit
      # @param url [URI] the release's page
      # @param manifest [Lifecycle::Manifest::Release]
      # @return [void]
      sig { params(env: ReleaseEnv, sha: String, url: URI::Generic, manifest: Lifecycle::Manifest::Release).void }
      def report(env, sha, url, manifest)
        @out.puts "released #{env.tag} (#{sha[0, Lifecycle::GitState::SHORT_SHA_LENGTH]}) → #{url}"
        manifest.archives.each { |archive| @out.puts "  #{archive.name} (#{archive.build_id})" }
        @out.puts "  #{manifest.file_name}"
        @out.puts "nothing deployed — `dev deploy <channel> --release #{env.tag.version}` ships it"
      end
    end
  end
end
