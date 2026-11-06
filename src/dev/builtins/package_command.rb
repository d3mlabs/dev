# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require "stringio"
require "time"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/command"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/lifecycle"

module Dev
  module Builtins
    # `dev package [BUILD] [--target T] [--platform P] [--config C]
    # [--no-build]`: turn one build into its artifact in the store — the
    # archive its target's packager makes of the install, stamped with
    # `build-id.json` (dev#192, K0, K4). `package` implies `build`,
    # make-like: the builder runs first unless the store's artifact for the
    # build is current — packaged from a clean tree at the commit the tree
    # is at now (Manifest::Artifact#current?) — or `--no-build` says to
    # trust the install as it is; a target with no `build:` has nothing to
    # run and packages alone. A target with `packager: none` is built,
    # never packaged, and is refused here by name.
    #
    # The stage: `before` consumes the argv into the build, resolves the
    # dispatch (the target's `environment:` under the host rule, or the
    # runner `--runner` names) and hands it the invocation a remote host
    # would run (`package <build> [--no-build]`, with the artifact to
    # bring back under `--fetch`) and, for a seam that runs here, the env
    # — reading the tree's state once (the same reading decides staleness
    # and is what the stamp records); the seam is the builder when needed,
    # then the packager, writing `<build>.<ext>` beside the install;
    # `after` hashes the archive, derives the build id and stamps the
    # manifest — last, so a directory without one reads as unpackaged —
    # reports the artifact, and names it to the enclosing Actions step
    # when there is one, which is how the generic workflow knows what
    # `--fetch` uploads. The packed archive crosses from the seam to
    # `after` through the env: the template's one channel between the
    # stages.
    class PackageCommand < LifecycleCommand
      extend T::Sig

      NAME = "package"
      NO_BUILD_FLAG = "--no-build"
      FETCH_FLAG = "--fetch"

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
        attr_reader :install

        # @return [Pathname] the archive path without its extension
        sig { returns(Pathname) }
        attr_reader :archive_stem

        # @return [Lifecycle::Builder, nil] nil: nothing to compile
        sig { returns(T.nilable(Lifecycle::Builder)) }
        attr_reader :builder

        sig { returns(Lifecycle::Packager) }
        attr_reader :packager

        # @return [Lifecycle::GitState] the tree as read in `before`
        sig { returns(Lifecycle::GitState) }
        attr_reader :state

        # @return [String, nil] why the builder does not run; nil when it does
        sig { returns(T.nilable(String)) }
        attr_reader :build_skipped

        # @return [Lifecycle::PackedArchive, nil] what the seam wrote
        sig { returns(T.nilable(Lifecycle::PackedArchive)) }
        attr_accessor :packed

        sig do
          params(
            build: Lifecycle::Build,
            install: Pathname,
            archive_stem: Pathname,
            builder: T.nilable(Lifecycle::Builder),
            packager: Lifecycle::Packager,
            state: Lifecycle::GitState,
            build_skipped: T.nilable(String),
          ).void
        end
        def initialize(build:, install:, archive_stem:, builder:, packager:, state:, build_skipped:)
          @build = build
          @install = install
          @archive_stem = archive_stem
          @builder = builder
          @packager = packager
          @state = state
          @build_skipped = build_skipped
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
      # @param ports [Lifecycle::Ports] the targets' builders and packagers
      # @param store [Lifecycle::Store] where the artifact goes
      # @param semver [String] the project's version, the build id's leading half
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
          semver: String,
          clock: T.proc.returns(Time),
          step_outputs: Lifecycle::StepOutputs,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(
        selector:, dispatcher:, listing:, ports:, store:, semver:,
        clock: -> { Time.now }, step_outputs: Lifecycle::StepOutputs.from_env, out: $stdout
      )
        super()
        @selector = selector
        @dispatcher = dispatcher
        @listing = listing
        @ports = ports
        @store = store
        @semver = semver
        @clock = clock
        @step_outputs = step_outputs
        @out = out
      end

      sig { override.returns(String) }
      def desc
        "Package a build into its artifact (package [BUILD] | --target T [--platform P] [--config C] [--no-build] [--runner L] [--fetch])\n" \
          "Builds first unless the artifact is current with the tree; the archive and build-id.json land in the store " \
          "of the host that packaged (--fetch brings them back from a remote one)."
      end

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags
        BuildSelector::FLAGS + [Cli::Flag.new(NO_BUILD_FLAG, desc: "package the install as it is, without building first")] +
          DispatchResolver::FLAGS +
          [Cli::Flag.new(FETCH_FLAG, desc: "after a remote package, download the artifact into this machine's store")]
      end

      sig { override.returns(T.nilable(Listing)) }
      def listing = @listing.listing(targets: packageable_targets)

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
        dispatch = @dispatcher.dispatch_for(build, runner: args.value(DispatchResolver::RUNNER_FLAG))
        dispatch.dispatch(invocation(build, no_build:, fetch: args.flag?(FETCH_FLAG))) do
          state = Lifecycle::GitState.read(context.project!.root)
          builder = @ports.builder_for(build.target)
          PackageEnv.new(
            build:,
            install: @store.install_dir(build),
            archive_stem: @store.archive_stem(build),
            builder:,
            packager: @ports.packager_for(build.target),
            state:,
            build_skipped: build_skipped(build, builder, state, no_build:),
          )
        end
      end

      sig { override.params(env: PackageEnv, context: ExecutionContext).void }
      def seam(env, context:)
        _ = context
        env.builder&.build(env.build, env.install) if env.build_skipped.nil?
        env.packed = env.packager.package(env.build, env.install, env.archive_stem)
      end

      sig { override.params(env: PackageEnv, context: ExecutionContext).void }
      def after(env, context:)
        _ = context
        packed = env.packed!
        now = @clock.call
        artifact = @store.stamp(
          Lifecycle::Manifest::Artifact.new(
            stamp: Lifecycle::Manifest::Stamp.now(now:),
            build: env.build,
            state: env.state,
            packaged_at: now,
            builder: env.builder&.name || NO_BUILDER,
            builder_version: env.builder&.version,
            build_id: Lifecycle::BuildId.derive(state: env.state, semver: @semver, now:),
            archive: packed.name,
            archive_sha256: Digest::SHA256.file(packed.archive.to_s).hexdigest,
          ),
        )
        @out.puts "build skipped: #{env.build_skipped}" if env.build_skipped
        @out.puts "packaged #{artifact.name} → #{artifact.archive} (#{artifact.manifest.build_id})"
        @step_outputs.artifact(artifact.name, files: packed.files + [artifact.dir / Lifecycle::Manifest::Artifact::FILE_NAME])
      end

      private

      # What the manifest records when the target declares no `build:`.
      NO_BUILDER = "none"

      # The verb as a remote host runs it: the build fully qualified, the
      # one flag the seam reads kept, and the artifact to bring back when
      # `--fetch` asked — into the store directory the build has here.
      #
      # @param build [Lifecycle::Build]
      # @param no_build [Boolean]
      # @param fetch [Boolean]
      # @return [Lifecycle::VerbInvocation]
      sig { params(build: Lifecycle::Build, no_build: T::Boolean, fetch: T::Boolean).returns(Lifecycle::VerbInvocation) }
      def invocation(build, no_build:, fetch:)
        words = [NAME, build.name]
        words << NO_BUILD_FLAG if no_build
        Lifecycle::VerbInvocation.new(
          words:, fetch: fetch ? Lifecycle::ArtifactFetch.new(name: build.name, into: @store.dir(build)) : nil,
        )
      end

      # @return [Array<Lifecycle::Target>] the targets `package` acts on
      sig { returns(T::Array[Lifecycle::Target]) }
      def packageable_targets = @selector.targets.select(&:packageable?)

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
      # does: nothing declared, `--no-build`, or an artifact current with
      # the tree (K4's staleness rule — the manifest carries this commit
      # and the tree it was packaged from was clean).
      #
      # @param build [Lifecycle::Build]
      # @param builder [Lifecycle::Builder, nil]
      # @param state [Lifecycle::GitState] the tree now
      # @param no_build [Boolean] the flag
      # @return [String, nil]
      sig do
        params(build: Lifecycle::Build, builder: T.nilable(Lifecycle::Builder), state: Lifecycle::GitState, no_build: T::Boolean)
          .returns(T.nilable(String))
      end
      def build_skipped(build, builder, state, no_build:)
        return "target '#{build.target}' declares no `build:`" unless builder
        return "#{NO_BUILD_FLAG} given" if no_build

        artifact = @store.artifact(build)
        return nil if artifact.nil? || !artifact.current?(state)

        "the artifact is current (#{artifact.manifest.build_id})"
      end
    end
  end
end
