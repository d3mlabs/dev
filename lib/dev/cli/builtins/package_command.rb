# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require "stringio"
require "time"
require "dev/cli/build_dispatcher"
require "dev/cli/build_listing"
require "dev/cli/build_selector"
require "dev/cli/command"
require "dev/cli/dispatch"
require "dev/cli/dispatch_resolver"
require "dev/lifecycle"

module Dev
  module Cli
    module Builtins
      # `dev package [<build>] [--target T] [--platform P] [--config C]
      # [--no-build]`: turn one build into its artifact in the store — the
      # archive its target's packager makes of the stage, stamped with
      # `build-id.json`. `package` implies `build`,
      # make-like: the builder runs first unless the store's artifact for the
      # build is current — packaged from a clean tree at the commit the tree
      # is at now (Manifest::Artifact#current?) — or `--no-build` says to
      # trust the stage as it is; a target with no `builder:` stages the
      # checkout's tracked files (the identity builder). A target with
      # `packager: none` is built, never packaged, and is refused here by
      # name.
      #
      # The stage: `before` consumes the argv into the build, resolves the
      # dispatch (the target's `environment:` under the host rule, the runner
      # `--runner` names, or the container `--container` forces) and hands it the invocation a remote host
      # would run (`package <build> [--no-build]`, with the artifact to
      # bring back under `--fetch`) and, for a seam that runs here, the env
      # — reading the tree's state once (the same reading decides staleness
      # and is what the stamp records); the seam is the builder when needed,
      # then the packager, writing `<build>.<ext>` beside the stage;
      # `after` hashes the archive, derives the build id and stamps the
      # manifest — last, so a directory without one reads as unpackaged —
      # reports the artifact with any deprecation the ports that ran have
      # to tell, and names it to the enclosing Actions step when there is
      # one, which is how the generic workflow knows what `--fetch`
      # uploads. The packed archive crosses from the seam to `after`
      # through the env: the template's one channel between the stages.
      #
      # `--attach <version>` is the verb's release form, what `dev
      # release` runs per release build: after the stamp, the artifact is
      # attached to the GitHub release of `v<version>` from the host that
      # packaged it — the archive under its release name, the build's
      # entry on the release's `release.json` — so a build whose
      # placement dispatches reaches the release without its bytes ever
      # crossing back (Lifecycle::ReleaseAttachment). The host refuses
      # before building what could not be the release's: a dirty tree, a
      # `VERSION` that is not the tag's, a tag with no release.
      #
      # Before the archive is written, the packager presents the tree as
      # it will ship to every channel whose `targets:` names the build
      # (Lifecycle::Acceptance): a destination that installs the tree by
      # rules of its own refuses an incomplete one here, where the
      # producer can fix it, rather than on the host installing it after
      # the release is immutable. The verb asks every publisher the same
      # way and knows no channel by name.
      class PackageCommand < LifecycleCommand
        extend T::Sig

        NAME = "package"
        NO_BUILD_FLAG = "--no-build"
        FETCH_FLAG = "--fetch"
        ATTACH_FLAG = "--attach"

        # `package` reached a target that declares `packager: none`.
        class NotPackageableError < ArgumentError; end

        # `after` ran before the seam left an archive — a wiring bug.
        class NothingPackedError < StandardError; end

        # What `before` resolves; the seam fills `packed` for `after`.
        class PackageEnv
          extend T::Sig

          sig { returns(Lifecycle::Build) }
          attr_reader :build

          sig { returns(Pathname) }
          attr_reader :stage

          # @return [Pathname] the archive path without its extension
          sig { returns(Pathname) }
          attr_reader :archive_stem

          sig { returns(Lifecycle::Builder) }
          attr_reader :builder

          sig { returns(Lifecycle::Packager) }
          attr_reader :packager

          # @return [Lifecycle::Acceptance] the channels receiving the build, shown the tree before it is archived
          sig { returns(Lifecycle::Acceptance) }
          attr_reader :acceptance

          # @return [Lifecycle::GitState] the tree as read in `before`
          sig { returns(Lifecycle::GitState) }
          attr_reader :state

          # @return [String, nil] why the builder does not run; nil when it does
          sig { returns(T.nilable(String)) }
          attr_reader :build_skipped

          # @return [Lifecycle::ReleaseTag, nil] the release the artifact is
          #   attached to after the stamp; nil for a plain package
          sig { returns(T.nilable(Lifecycle::ReleaseTag)) }
          attr_reader :attach

          # @return [Lifecycle::PackedArchive, nil] what the seam wrote
          sig { returns(T.nilable(Lifecycle::PackedArchive)) }
          attr_accessor :packed

          sig do
            params(
              build: Lifecycle::Build,
              stage: Pathname,
              archive_stem: Pathname,
              builder: Lifecycle::Builder,
              packager: Lifecycle::Packager,
              acceptance: Lifecycle::Acceptance,
              state: Lifecycle::GitState,
              build_skipped: T.nilable(String),
              attach: T.nilable(Lifecycle::ReleaseTag),
            ).void
          end
          def initialize(build:, stage:, archive_stem:, builder:, packager:, acceptance:, state:, build_skipped:, attach: nil)
            @build = build
            @stage = stage
            @archive_stem = archive_stem
            @builder = builder
            @packager = packager
            @acceptance = acceptance
            @state = state
            @build_skipped = build_skipped
            @attach = attach
            @packed = T.let(nil, T.nilable(Lifecycle::PackedArchive))
          end

          # @return [Lifecycle::PackedArchive]
          # @raise [NothingPackedError]
          sig { returns(Lifecycle::PackedArchive) }
          def packed!
            @packed || raise(NothingPackedError, "package: `after` ran before the seam packed #{@build}")
          end
        end

        Env = type_member { { fixed: PackageEnv } }

        # @param selector [BuildSelector] argv → the build
        # @param dispatcher [BuildDispatcher] the build → where it runs
        # @param listing [BuildListing] what the usage and completion list
        # @param ports [Lifecycle::Ports] the targets' builders and packagers, the channels' publishers
        # @param store [Lifecycle::Store] where the artifact goes
        # @param attachment [Lifecycle::ReleaseAttachment] the artifact onto its release, under `--attach`
        # @param channels [Array<Lifecycle::Channel>] the project's channels
        #   with a protocol; the ones accepting a build are shown its tree
        # @param clock [Proc] the packaging instant (injectable for tests)
        # @param step_outputs [Lifecycle::StepOutputs] the enclosing Actions step's, or none
        # @param out [IO, StringIO]
        sig do
          params(
            selector: BuildSelector,
            dispatcher: BuildDispatcher,
            listing: BuildListing,
            ports: Lifecycle::Ports,
            store: Lifecycle::Store,
            attachment: Lifecycle::ReleaseAttachment,
            channels: T::Array[Lifecycle::Channel],
            clock: T.proc.returns(Time),
            step_outputs: Lifecycle::StepOutputs,
            out: T.any(IO, StringIO),
          ).void
        end
        def initialize(
          selector:, dispatcher:, listing:, ports:, store:, attachment:, channels: [],
          clock: -> { Time.now }, step_outputs: Lifecycle::StepOutputs.from_env, out: $stdout
        )
          super()
          @selector = selector
          @dispatcher = dispatcher
          @listing = listing
          @ports = ports
          @store = store
          @attachment = attachment
          @channels = channels
          @clock = clock
          @step_outputs = step_outputs
          @out = out
        end

        sig { override.returns(String) }
        def desc
          "Package a build into its artifact\n" \
            "Builds first unless the artifact is current with the tree; the archive and build-id.json land in the store " \
            "of the host that packaged (--fetch brings them back from a remote one; --attach puts the archive on a release from there)."
        end

        sig { override.returns(T::Array[Cli::Positional]) }
        def positionals
          [@selector.positional]
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          BuildSelector::FLAGS + [Cli::Flag.new(NO_BUILD_FLAG, desc: "package the stage as it is, without building first")] +
            DispatchResolver::FLAGS +
            [
              Cli::Flag.new(FETCH_FLAG, desc: "after a remote package, download the artifact into this machine's store"),
              Cli::Flag.new(
                ATTACH_FLAG, takes_value: true,
                desc: "attach the artifact to the GitHub release of this version from the host that packaged it (what `dev release` runs per build)",
              ),
            ]
        end

        sig { override.returns(T.nilable(Listing)) }
        def listing
          @listing.listing(targets: packageable_targets)
        end

        sig { override.params(words: T::Array[String]).returns(T::Array[String]) }
        def completions(words)
          _ = words
          @listing.completions(targets: packageable_targets)
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[PackageEnv]) }
        def before(args:, context:)
          build = @selector.select(args)
          assert_packageable!(build.target)
          no_build = args.flag?(NO_BUILD_FLAG)
          attach = args.value(ATTACH_FLAG)&.then { |version| Lifecycle::ReleaseTag.new(version) }
          dispatch = @dispatcher.dispatch_for(
            build, runner: args.value(DispatchResolver::RUNNER_FLAG), container: args.flag?(DispatchResolver::CONTAINER_FLAG),
          )
          dispatch.dispatch(invocation(build, no_build:, fetch: args.flag?(FETCH_FLAG), attach:)) do
            root = context.project!.root
            state = Lifecycle::GitState.read(root)
            # Refused here, before the builder runs: an attach of what is
            # not the release's would be a build for nothing.
            @attachment.assert_attachable!(attach, state:, version: Lifecycle::ProjectVersion.declared(root)) if attach
            PackageEnv.new(
              build:,
              stage: @store.stage_dir(build),
              archive_stem: @store.archive_stem(build),
              builder: @ports.builder_for(build.target),
              packager: @ports.packager_for(build.target),
              acceptance: acceptance_for(build),
              state:,
              build_skipped: build_skipped(build, state, no_build:),
              attach:,
            )
          end
        end

        sig { override.params(env: PackageEnv, context: ExecutionContext).void }
        def seam(env, context:)
          _ = context
          env.builder.build(env.build, env.stage) if env.build_skipped.nil?
          env.packed = env.packager.package(env.build, env.stage, env.archive_stem, acceptance: env.acceptance)
        end

        # The build id's semver is read from the tree now, not at wiring:
        # `release` bumps `VERSION` and then packages, and the artifacts of
        # the cut must carry the version they are released under.
        sig { override.params(env: PackageEnv, context: ExecutionContext).void }
        def after(env, context:)
          packed = env.packed!
          now = @clock.call
          semver = Lifecycle::ProjectVersion.read(context.project!.root)
          artifact = @store.stamp(
            Lifecycle::Manifest::Artifact.new(
              stamp: Lifecycle::Manifest::Stamp.now(now:),
              build: env.build,
              state: env.state,
              packaged_at: now,
              builder: env.builder.name,
              builder_version: env.builder.version,
              build_id: Lifecycle::BuildId.derive(state: env.state, semver:, now:),
              archive: packed.name,
              archive_sha256: Digest::SHA256.file(packed.archive.to_s).hexdigest,
            ),
          )
          @out.puts "build skipped: #{env.build_skipped}" if env.build_skipped
          @out.puts "packaged #{artifact.name} → #{artifact.archive} (#{artifact.manifest.build_id})"
          deprecations(env).each { |line| @out.puts line }
          @step_outputs.artifact(artifact.name, files: packed.files + [artifact.dir / Lifecycle::Manifest::Artifact::FILE_NAME])
          attach = env.attach
          return if attach.nil?

          entry = @attachment.attach(artifact, tag: attach)
          @out.puts "attached #{entry.name} to #{attach}'s release (#{entry.build_id})"
        end

        private

        # What the ports that ran have to tell: the builder's only when it
        # ran (a skipped builder read nothing), the packager's always.
        #
        # @param env [PackageEnv]
        # @return [Array<String>]
        sig { params(env: PackageEnv).returns(T::Array[String]) }
        def deprecations(env)
          (env.build_skipped.nil? ? env.builder.deprecations : []) + env.packager.deprecations
        end

        # The verb as a remote host runs it: the build fully qualified, the
        # flags the seam and `after` read kept (`--no-build`; `--attach`,
        # which the host carries out, the release being where it is), and
        # the artifact to bring back when `--fetch` asked — into the store
        # directory the build has here.
        #
        # @param build [Lifecycle::Build]
        # @param no_build [Boolean]
        # @param fetch [Boolean]
        # @param attach [Lifecycle::ReleaseTag, nil]
        # @return [Lifecycle::VerbInvocation]
        sig do
          params(build: Lifecycle::Build, no_build: T::Boolean, fetch: T::Boolean, attach: T.nilable(Lifecycle::ReleaseTag))
            .returns(Lifecycle::VerbInvocation)
        end
        def invocation(build, no_build:, fetch:, attach:)
          words = [NAME, build.name]
          words << NO_BUILD_FLAG if no_build
          words.push(ATTACH_FLAG, attach.version) if attach
          Lifecycle::VerbInvocation.new(
            words:, fetch: fetch ? Lifecycle::ArtifactFetch.new(name: build.name, into: @store.dir(build)) : nil,
          )
        end

        # @return [Array<Lifecycle::Target>] the targets `package` acts on
        sig { returns(T::Array[Lifecycle::Target]) }
        def packageable_targets
          @selector.targets.select(&:packageable?)
        end

        # The destinations shown the build's tree before it is archived:
        # every channel whose accept set holds the build, with its
        # publisher, in channel order.
        #
        # @param build [Lifecycle::Build]
        # @return [Lifecycle::Acceptance]
        # @raise [Lifecycle::Ports::UnknownPublisherError]
        sig { params(build: Lifecycle::Build).returns(Lifecycle::Acceptance) }
        def acceptance_for(build)
          receiving = @channels.select { |channel| channel.accepts?(build) }
          Lifecycle::Acceptance.new(acceptors: receiving.to_h { |channel| [channel, @ports.publisher_for(channel)] })
        end

        # @param target [Lifecycle::Target]
        # @return [void]
        # @raise [NotPackageableError]
        sig { params(target: Lifecycle::Target).void }
        def assert_packageable!(target)
          return if target.packageable?

          raise NotPackageableError,
            "target '#{target}' declares `packager: none` — it is built, never packaged; `dev build #{target}` builds it"
        end

        # Why the builder does not run before the packager, or nil when it
        # does: `--no-build`, or an artifact current with the tree (the
        # manifest carries this commit and the tree it was packaged from
        # was clean).
        #
        # @param build [Lifecycle::Build]
        # @param state [Lifecycle::GitState] the tree now
        # @param no_build [Boolean] the flag
        # @return [String, nil]
        sig { params(build: Lifecycle::Build, state: Lifecycle::GitState, no_build: T::Boolean).returns(T.nilable(String)) }
        def build_skipped(build, state, no_build:)
          return "#{NO_BUILD_FLAG} given" if no_build

          artifact = @store.artifact(build)
          return nil if artifact.nil? || !artifact.current?(state)

          "the artifact is current (#{artifact.manifest.build_id})"
        end
      end
    end
  end
end
