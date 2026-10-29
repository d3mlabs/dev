# typed: strict
# frozen_string_literal: true

require "digest"
require "etc"
require "fileutils"
require "pathname"
require "securerandom"
require "tmpdir"
require "yaml"

require "dev/build_watcher"
require "dev/container_context"
require "dev/container_engine"
require "dev/data_root"
require "dev/platform"
require "dev/engine_resources_check"
require "dev/environment_image"
require "dev/gh_auth"
require "dev/registry_login"

module Dev
  # Content-addressed Docker image management for build containers.
  #
  # The image is the project's `image` pin (dev#277, `Dev::EnvironmentImage`):
  # its tag is the digest of the Dockerfile dev generates, so a change to the
  # floor, the platform, the apt set or dev's template is a new tag and a
  # rebuild. `ensure_environment_image!` resolves it: local → (publisher:
  # registry manifest) → pull → build → push, the registry entered once, by
  # `Dev::RegistryLogin`, around whatever touches it.
  #
  # The hand-written-Dockerfile path (`ensure_image!`, `content_tag`,
  # `image_with_tag`: a tag from the hash of Dockerfile + .dockerignore +
  # deps.lock plus project globs) is deprecated and goes with d3mlabs/dev#311.
  #
  # Every docker invocation rides an injected Dev::ContainerEngine (the
  # per-user container substrate — see that class), so which daemon serves a
  # build is a provisioning decision, never an assumption here. Pure tag and
  # name computation stays on the class (no engine, no side effects).
  #
  # Usage:
  #   BuildContainer.new(engine:).ensure_environment_image!(image)
  #     # pulls or builds the image, returns its ref (image.ref)
  class BuildContainer
    extend T::Sig

    # A bind-mount was composed for an engine whose daemon cannot see local
    # paths. Both shipped engines answer local_mounts? true; the future
    # remote engine brings its sync strategy instead of reaching this raise.
    class LocalMountsUnsupportedError < RuntimeError; end

    # The per-uid secrets dir under the data root failed verification (symlink,
    # non-directory, or owned by another user). Writing 0600 secret files into
    # a dir someone else controls lets its owner swap contents between file
    # write and container bind mount, so this is a hard stop, never a fallback.
    class SecretDirCompromisedError < RuntimeError; end

    # `docker stop` on one of this checkout's containers failed.
    class StopFailedError < RuntimeError; end

    # `docker build` returned nonzero.
    class BuildFailedError < RuntimeError; end

    # The deprecated Dockerfile path was asked for a config that names no
    # image (its image is the lock's pin — resolve through EnvironmentImage).
    class NoDockerfileImageError < RuntimeError; end

    # Which hand-written-Dockerfile inputs are deprecated, said once per
    # process so a `dev` invocation that resolves the image twice does not
    # nag twice.
    DOCKERFILE_DEPRECATION =
      "dev: the project Dockerfile + build.container.image/registry path is deprecated — " \
      "declare an `image` block in dependencies.rb (the generated image is the pin); " \
      "the Dockerfile path goes with d3mlabs/dev#311"

    # The label contract, read back by `dev container …` here and by
    # `dev engine down/status` through ContainerEngine#running_containers.
    # ContainerEngine owns the two labels it decodes (managed, project_root);
    # these three are the container layer's own: which checkout (workspace
    # id — the set-operation key), its short name, and the image it runs.
    PROJECT_LABEL = "dev.project"
    WORKSPACE_LABEL = "dev.workspace"
    IMAGE_LABEL = "dev.image"

    # One of this checkout's containers, as `docker ps -a` reports it.
    class ServiceContainer < T::Struct
      const :name, String
      const :running, T::Boolean
      # The volume mounted at the Linuxbrew prefix; nil when unknown.
      const :prefix_volume, T.nilable(String), default: nil
    end

    # What `dev container status` renders: image presence on both sides and
    # this image's containers in the checkout, the current tag's one named
    # so stale siblings (reaped on the next `up`) can be told apart.
    # `in_registry` is nil when there was no credential to ask with.
    class ServiceStatus < T::Struct
      const :image_tag, String
      const :local_image, T::Boolean
      const :in_registry, T.nilable(T::Boolean)
      const :current_container_name, String
      const :containers, T::Array[ServiceContainer]
    end

    # A docker command dev spawns, in two halves: the argv, where every
    # injected variable is a bare `-e NAME`, and the env those names
    # resolve in (docker reads a valueless `-e` from the client's own
    # environment). argv is world-readable — `ps`, /proc — and the env is
    # the process's own, so a credential appears in the second half and
    # never in the first (dev#317). The caller spawns argv with env merged
    # over the engine's.
    class Invocation < T::Struct
      const :argv, T::Array[String]
      const :env, T::Hash[String, String]
    end

    # Always-hashed inputs. deps.lock joins the Dockerfile so a dependency
    # bump invalidates a prewarmed image. Missing files are skipped (see
    # content_tag).
    CONTENT_FILES = ["Dockerfile", ".dockerignore", "deps.lock"].freeze
    TAG_PREFIX = "content-"

    # Rosetta-for-Linux forwards cross-thread signals through rt_tgsigqueueinfo
    # and aborts the whole process when the kernel answers EAGAIN ("rosetta
    # error: rt_tgsigqueueinfo failed in pend_signal: 11") — no backoff, because
    # retrying inside its own signal-forwarding path risks deadlock. The queue
    # fills because .NET GC suspensions across UBT/UHT's hundreds of threads
    # each become a queued signal under emulation, and RLIMIT_SIGPENDING is one
    # per-UID bucket shared by every build process (RAM-scaled default, ~96k on
    # a 24GB VM). The bursts are transient — the queue drains in milliseconds
    # once a suspension completes — so a wide bucket absorbs them. The limit is
    # a cap, not a reservation: ~80 bytes of kernel memory per actually-queued
    # signal, worst case ~80MB, nothing at rest. Applied to every build/prewarm
    # run; harmless on native hosts.
    SIGPENDING_ULIMIT = ["--ulimit", "sigpending=1000000"].freeze

    # Where the container's data root is mounted in every container dev
    # creates — the Linux data root's own path (DataRoot::LINUX_ROOT), so a
    # Linux host's bind mount reads the same on both sides.
    DATA_ROOT_MOUNT = Dev::DataRoot::LINUX_ROOT

    # The container's data root is its own, not the host's (ADR-0008): a
    # named volume on the engine's disk, one per VM and shared by every
    # project — one data root per build host, as one ~/.dev per machine.
    # Docker initialises an empty named volume from the image's content and
    # ownership at the mount point, so a base image that declares the
    # directory builder-owned yields a writable volume with no chown.
    DATA_ROOT_VOLUME = "dev-data-root"

    # Linuxbrew's prefix is a second mount point, not a subtree of the data
    # root: brew's fixed path must be a real directory (bottles refuse a
    # symlinked prefix), and a volume-subpath mount is neither created nor
    # initialised by docker. Same volume semantics as the data root. The
    # generated image puts the prefix on PATH (EnvironmentImage), so the two
    # are one constant.
    #
    # A brew prefix has one owner, and brew's only writer is that owner
    # (dev#337). On a Mac the VM is one user's, so one volume per VM. On
    # Linux the engine is shared by the host's users — the operator and the
    # runner user (dev#310) each run containers as themselves — so the
    # volume is per host user: `dev-linuxbrew-<user>` (see .prefix_volume).
    LINUXBREW_MOUNT = EnvironmentImage::LINUXBREW_PREFIX
    LINUXBREW_VOLUME = "dev-linuxbrew"

    # @return [Dev::ContainerEngine] the engine every docker invocation rides
    sig { returns(Dev::ContainerEngine) }
    attr_reader :engine

    # @param engine [Dev::ContainerEngine] resolved for the invoking user
    # @param resources_check [Dev::EngineResourcesCheck] the engine-vs-hint
    #   gate every image resolution passes through first
    # @param registry_login [Dev::RegistryLogin, nil] the registry session
    #   around pulls and pushes; defaults to one over this engine and the registry credential (gh's token, or DEV_REGISTRY_TOKEN)
    # @param host_os [String] "darwin" / "linux" / "windows" — the shape of
    #   the container's data root (ADR-0008: a volume behind a Mac's VM
    #   boundary, the host's own directory bind-mounted on Linux)
    # @param host_user [String] the host user's name, whose prefix volume a
    #   Linux container mounts
    sig do
      params(
        engine: Dev::ContainerEngine,
        resources_check: Dev::EngineResourcesCheck,
        registry_login: T.nilable(Dev::RegistryLogin),
        host_os: String,
        host_user: String,
      ).void
    end
    def initialize(engine:, resources_check: Dev::EngineResourcesCheck.new, registry_login: nil, host_os: Dev::Platform.os,
                   host_user: BuildContainer.host_user)
      @engine = engine
      @resources_check = resources_check
      @registry_login = T.let(registry_login || Dev::RegistryLogin.new(engine:), Dev::RegistryLogin)
      @host_os = host_os
      @host_user = host_user
    end

    class << self
      extend T::Sig

      # The host user dev runs as, by name (the volume is named after it).
      #
      # @return [String]
      sig { returns(String) }
      def host_user
        Etc.getpwuid(Process.uid)&.name || ENV.fetch("USER", Process.uid.to_s)
      end

      # The Linuxbrew prefix volume a container mounts: the host user's own
      # on Linux, the VM's one on a Mac.
      #
      # @param host_os [String] "darwin" / "linux"
      # @param host_user [String] the host user's name
      # @return [String] the docker volume name
      sig { params(host_os: String, host_user: String).returns(String) }
      def prefix_volume(host_os: Dev::Platform.os, host_user: self.host_user)
        host_os == "linux" ? "#{LINUXBREW_VOLUME}-#{host_user}" : LINUXBREW_VOLUME
      end

      # Compute the content-addressed tag from Dockerfile + lockfiles + globs.
      #
      # @param project_root    [Pathname] project root containing Dockerfile etc.
      # @param extra_globs      [Array<String>] additional project-relative globs whose
      #   matched files contribute to the hash (path + content), e.g. a mod's
      #   *.Build.cs. Sorted for determinism; missing matches contribute nothing.
      # @param structure_globs  [Array<String>] project-relative globs whose matched
      #   *paths* (not contents) contribute to the hash. Use for inputs where the set
      #   of matching files is structural but their contents are not, e.g. one
      #   *.Build.cs per build module: adding/removing a module changes the path set
      #   (and the tag), while editing a module's dependency list does not. Sorted
      #   for determinism; missing matches contribute nothing.
      # @return [String] tag like "content-a1b2c3d4e5f6"
      sig do
        params(
          project_root: Pathname,
          extra_globs: T::Array[String],
          structure_globs: T::Array[String],
        ).returns(String)
      end
      def content_tag(project_root:, extra_globs: [], structure_globs: [])
        root = Pathname(project_root)
        file_content = CONTENT_FILES
          .map { |f| root / f }
          .select(&:exist?)
          .map(&:read)
          .join

        # A recursive glob (e.g. "bin/image/**/*") also matches directories; hash
        # only files. The files under a matched dir are matched in their own right,
        # so skipping the dir entry loses nothing — and avoids Errno::EISDIR on read.
        glob_content = extra_globs
          .flat_map { |pattern| Dir.glob(pattern, base: root.to_s) }
          .uniq
          .select { |rel| (root / rel).file? }
          .sort
          .map { |rel| "#{rel}\n#{(root / rel).read}" }
          .join

        # Paths only: the *existence* of these files matters, not their contents.
        structure_content = structure_globs
          .flat_map { |pattern| Dir.glob(pattern, base: root.to_s) }
          .uniq
          .sort
          .join("\n")

        hash = Digest::SHA256.hexdigest(file_content + glob_content + structure_content)[0, 12]
        "#{TAG_PREFIX}#{hash}"
      end

      # Deprecated (d3mlabs/dev#311): full Dockerfile-image reference with
      # content-addressed tag.
      #
      # @param config       [Dev::BuildContainerConfig]
      # @param project_root [Pathname]
      # @return [String] e.g. "jpduchesne89/snappy-linux:content-a1b2c3d4e5f6"
      # @raise [NoDockerfileImageError] when the config names no image
      sig { params(config: Dev::BuildContainerConfig, project_root: Pathname).returns(String) }
      def image_with_tag(config, project_root:)
        image_ref = config.image_ref
        if image_ref.nil?
          raise NoDockerfileImageError,
            "build.container names no image/registry: the project's image is its lock's `image` pin"
        end

        globs = config.respond_to?(:content_globs) ? config.content_globs : []
        structure_globs = config.respond_to?(:structure_globs) ? config.structure_globs : []
        "#{image_ref}:#{content_tag(project_root:, extra_globs: globs, structure_globs:)}"
      end

      # Container name for image_tag + workspace: "dev-<image>-<workspace>-<tag>",
      # registry dropped and any char Docker forbids in a name (notably ':') replaced
      # with '-'. E.g. "reg/snappy-linux:content-abc" in /work/snappy ->
      # "dev-snappy-linux-9f86d08-content-abc".
      #
      # The <workspace> segment is what keys the persistent container to the checkout
      # it is bind-mounted to. Without it the container is keyed by image tag ALONE,
      # so a SECOND checkout of the same project (e.g. a CI runner's actions/checkout
      # vs. a manual clone elsewhere on the same machine) finds the first checkout's
      # container by name and reuses it — still bind-mounted to the FIRST checkout —
      # silently building and testing the wrong tree on every run. Keying by workspace
      # gives each checkout its own long-lived container, each bound correctly, with
      # no cross-thrash when a machine is both a dev box and a CI runner.
      sig { params(image_tag: String, project_root: Pathname).returns(String) }
      def service_container_name(image_tag, project_root)
        tag = T.must(image_tag.split(":").last)
        "#{service_container_prefix(image_tag, project_root)}#{sanitize_container_name(tag)}"
      end

      # What every container of this image in this checkout is named under,
      # whatever its tag: the set key for "this image's containers here" —
      # a project with several persisted images (dev#307) has one per image,
      # and one image's stale container is never another's.
      #
      # @param image_tag    [String]
      # @param project_root [Pathname]
      # @return [String] `dev-<image>-<workspace>-`
      sig { params(image_tag: String, project_root: Pathname).returns(String) }
      def service_container_prefix(image_tag, project_root)
        "dev-#{sanitize_container_name(image_basename(image_tag))}-#{workspace_id(project_root)}-"
      end

      # Bare image name (no registry, no tag). E.g.
      # "reg/snappy-linux:content-abc" -> "snappy-linux".
      sig { params(image_tag: String).returns(String) }
      def image_basename(image_tag)
        T.must(T.must(image_tag.split("/").last).split(":").first)
      end

      # Short, stable identifier for the checkout a persistent container is bound to,
      # so the container name is unique per workspace (see service_container_name).
      # Hash of the resolved real path: different directories differ, the same
      # directory is stable across runs, and symlinked paths normalize to one id.
      sig { params(project_root: Pathname).returns(String) }
      def workspace_id(project_root)
        T.must(Digest::SHA256.hexdigest(workspace_path(project_root))[0, 10])
      end

      # The checkout's one canonical path: resolved real path, so a symlinked
      # route and the direct one name the same workspace. A root that does
      # not exist (tests, a removed checkout) falls back to the expanded path.
      #
      # @param project_root [Pathname]
      # @return [String]
      sig { params(project_root: Pathname).returns(String) }
      def workspace_path(project_root)
        File.realpath(project_root.to_s)
      rescue Errno::ENOENT
        File.expand_path(project_root.to_s)
      end

      # The labels every container dev starts for a checkout carries (see
      # the constants above). `docker ps --filter label=…` on any of them is
      # the set operation; a name match never is.
      #
      # @param image_tag    [String]   full image:tag the container runs
      # @param project_root [Pathname] the checkout it is bind-mounted to
      # @return [Hash{String => String}] label => value
      sig { params(image_tag: String, project_root: Pathname).returns(T::Hash[String, String]) }
      def service_labels(image_tag, project_root)
        path = workspace_path(project_root)
        {
          Dev::ContainerEngine::MANAGED_LABEL => "true",
          Dev::ContainerEngine::PROJECT_ROOT_LABEL => path,
          PROJECT_LABEL => File.basename(path),
          WORKSPACE_LABEL => workspace_id(project_root),
          IMAGE_LABEL => image_tag,
        }
      end

      # @param image_tag    [String]
      # @param project_root [Pathname]
      # @return [Array<String>] `--label key=value` pairs for a docker run
      sig { params(image_tag: String, project_root: Pathname).returns(T::Array[String]) }
      def label_flags(image_tag, project_root)
        service_labels(image_tag, project_root).flat_map { |key, value| ["--label", "#{key}=#{value}"] }
      end

      sig { params(str: String).returns(String) }
      def sanitize_container_name(str)
        str.gsub(/[^a-zA-Z0-9_.-]/, "-")
      end
    end

    # Ensure the project's environment image exists on this engine: local →
    # pull → build from the generated Dockerfile → push when publishing.
    # Returns the image's ref.
    #
    # The local check comes first and needs no credential: an image already
    # here is usable offline, and a box that built it by hand is honoured.
    # Everything past it touches the registry and runs inside one
    # RegistryLogin session — read scope to pull, write scope to publish.
    #
    # Publishing is the *provisioning* guarantee (see ensure_image!): the
    # digest you built or found is pushed — a local hit if the registry lacks
    # the tag, a fresh build always; a pull hit is the registry's own copy
    # and needs nothing. A tag is first-publisher-wins — apt is not
    # reproducible, so two builds of one tag differ in bytes, and dev never
    # replaces a published one. The old publisher shortcut (ask the registry
    # first, skip the pull on a hit) is gone: the one host it spared a pull
    # is a box that is the environment, and that box's first `dev up` pays
    # it once.
    #
    # The build's context is a temp dir holding only the generated
    # Dockerfile: nothing from the checkout enters the image (that is the
    # point — the image is OS state, the lock is the project's), and the
    # digest the marker records arrives as a build arg so the text the
    # digest was computed over is exactly the text built.
    #
    # @param image     [Dev::EnvironmentImage] the lock's image pin, materialised
    # @param publish   [Boolean] whether to make the registry hold the image
    # @param resources [Dev::EngineResources::Hint, nil] the project's
    #   engine-size hint, measured first (EngineResourcesCheck)
    # @return [String] image.ref
    # @raise [EngineResourcesCheck::UndersizedEngineError, RegistryLogin::LoginFailedError,
    #   GhAuth::MissingScopeError, BuildFailedError]
    sig do
      params(
        image: Dev::EnvironmentImage,
        publish: T::Boolean,
        resources: T.nilable(Dev::EngineResources::Hint),
      ).returns(String)
    end
    def ensure_environment_image!(image, publish: false, resources: nil)
      @resources_check.check!(engine: @engine, hint: resources)
      ref = image.ref

      if local_image?(ref)
        $stderr.puts "dev: Container image found locally — #{ref}"
        @registry_login.with(image.registry_host, publish: true) { publish!(ref) } if publish
        return ref
      end

      @registry_login.with(image.registry_host, publish:) do
        if pull(ref)
          $stderr.puts "dev: Container image cache hit — #{ref}"
        else
          $stderr.puts "dev: Container image cache miss — building #{ref}"
          build_generated!(image)
          push!(ref) if publish
        end
      end
      ref
    end

    # Build the generated Dockerfile: a temp dir as the (otherwise empty)
    # context, `--platform` pinned to the declared one so the floor's index
    # resolves to the platform the lock names rather than the daemon's.
    #
    # @param image [Dev::EnvironmentImage]
    # @raise [BuildFailedError]
    sig { params(image: Dev::EnvironmentImage).void }
    def build_generated!(image)
      Dir.mktmpdir("dev-image-") do |context|
        dockerfile = File.join(context, "Dockerfile")
        File.write(dockerfile, image.dockerfile)
        arg_flags = image.build_args.flat_map { |name, value| ["--build-arg", "#{name}=#{value}"] }
        args = [
          "build", "--progress=plain", "--platform", image.platform, "-t", image.ref,
          *arg_flags, "-f", dockerfile, context,
        ]
        success = @engine.run(args, env: { "DOCKER_BUILDKIT" => "1" })
        raise BuildFailedError, "Docker build failed for #{image.ref}" unless success
      end
    end

    # Deprecated (d3mlabs/dev#311): ensure the hand-written-Dockerfile image
    # exists: use a local image if present, pull from registry if available,
    # otherwise build. Returns the full image:tag string.
    #
    # The local check comes first so images built manually are honored.
    #
    # build_args_provider / secrets_provider are lazy sources of docker
    # --build-arg and BuildKit --secret values (e.g. credentials). They are only
    # called on a cache miss so cache hits never trigger credential resolution or
    # prompts.
    #
    # Publishing (`publish: true`) is the *provisioning* guarantee: after the
    # image is resolved by any path — built OR found locally — it is published to
    # the shared registry so other machines can pull it. The local-hit case is
    # the one that matters: the machine that originally built the image (e.g. the
    # CI runner) keeps hitting its own local copy on every run, so without
    # publish-on-hit the registry it is meant to populate stays empty forever and
    # no other machine can ever pull. `push:` (legacy) only pushes a freshly built
    # image; `publish:` subsumes it and additionally covers the local hit, so the
    # provisioning step sets `publish: true` while build/run steps leave both off.
    # Publishing also short-circuits the other way: with no local copy, the
    # registry is asked for the manifest before anything is pulled — a hit means
    # the publisher's job is already done, and a host that is itself the build
    # environment (see ContainerUpCommand) never needs the image locally at all.
    #
    # Before any image work, the engine is measured against the project's
    # engine hint (EngineResourcesCheck) — read-only; `dev up` is the one
    # place a VM gets resized. A build on half the cores the repo tuned for is
    # a slow, silent failure, and this is the last place to make it loud.
    #
    # @param config              [Dev::BuildContainerConfig]
    # @param project_root        [Pathname]
    # @param push                [Boolean] whether to push a freshly built image (default: true)
    # @param publish             [Boolean] whether to publish the resolved image to the
    #   registry, even on a local hit (default: false — only the provisioning step opts in)
    # @param build_args_provider [#call, nil] returns Hash{String => String} of build args
    # @param secrets_provider    [#call, nil] returns Hash{String => String} of secret id => value
    # @param resources           [Dev::EngineResources::Hint, nil] the project's engine-size hint
    # @return [String] the full image:tag string
    # @raise [EngineResourcesCheck::UndersizedEngineError] when the engine falls short of the hint (enforce mode)
    sig do
      params(
        config: Dev::BuildContainerConfig,
        project_root: Pathname,
        push: T::Boolean,
        publish: T::Boolean,
        build_args_provider: T.nilable(T.proc.returns(T::Hash[String, String])),
        secrets_provider: T.nilable(T.proc.returns(T::Hash[String, String])),
        resources: T.nilable(Dev::EngineResources::Hint),
      ).returns(String)
    end
    def ensure_image!(config, project_root:, push: true, publish: false,
                      build_args_provider: nil, secrets_provider: nil, resources: nil)
      $stderr.puts DOCKERFILE_DEPRECATION
      @resources_check.check!(engine: @engine, hint: resources)
      tag = self.class.image_with_tag(config, project_root:)

      if local_image?(tag)
        $stderr.puts "dev: Container image found locally — #{tag}"
        publish!(tag) if publish
        return tag
      end

      # A publisher's job is to make the registry hold the image, not to hold
      # it itself: a manifest lookup settles that before paying for a pull.
      if publish && registry_has?(tag)
        $stderr.puts "dev: Container image already published — #{tag}"
        return tag
      end

      if pull(tag)
        $stderr.puts "dev: Container image cache hit — #{tag}"
        return tag
      end

      $stderr.puts "dev: Container image cache miss — building #{tag}"
      build_args = build_args_provider ? build_args_provider.call : {}
      secrets = secrets_provider ? secrets_provider.call : {}

      prewarm = config.respond_to?(:prewarm) ? config.prewarm : nil
      if prewarm
        build_and_prewarm!(tag, config:, project_root:, build_args:, secrets:, prewarm:)
      else
        build!(tag, project_root:, build_args:, secrets:)
      end

      # A publisher only gets here after a registry miss, so the fresh build is
      # unpublished by construction — push it without asking again.
      push!(tag) if push || publish
      tag
    end

    # Two-phase image creation for prewarmed images: build a cheap base from the
    # Dockerfile, then run the prewarm command in a container with the build-dep
    # volumes mounted and secrets delivered as files, and commit the result to the
    # content-addressed tag.
    #
    # Why not a single `docker build` with the dependency as a BuildKit
    # build-context? BuildKit *streams* a build-context from the client on demand;
    # for a large, randomly-read dependency (e.g. a ~30GB engine read during
    # compilation) that transport stalls/deadlocks, especially under emulation. A
    # plain `-v` volume (virtiofs on colima) is the robust path the runtime
    # already uses, so the prewarm reuses it.
    #
    # @param tag          [String] final content-addressed tag to commit
    # @param config       [Dev::BuildContainerConfig]
    # @param project_root [Pathname]
    # @param build_args   [Hash{String => String}]
    # @param secrets      [Hash{String => String}] secret id => value
    # @param prewarm      [String] shell command to run inside the base container
    sig do
      params(
        tag: String,
        config: Dev::BuildContainerConfig,
        project_root: Pathname,
        build_args: T::Hash[String, String],
        secrets: T::Hash[String, String],
        prewarm: String,
      ).void
    end
    def build_and_prewarm!(tag, config:, project_root:, build_args:, secrets:, prewarm:)
      base_tag = "#{tag}-base"
      # The base is engine-free and secret-free: no BuildKit secrets. Those are
      # supplied to the prewarm run, not the Dockerfile. Volumes mount as
      # configured: nothing of the host's data root is resolved into them.
      build!(base_tag, project_root:, build_args:, secrets: {})
      prewarm_commit!(base_tag, tag, volumes: config.volumes, prewarm:, secrets:)
    ensure
      # The committed image references the base's layers, so dropping the base tag
      # frees the name without removing shared data. T.must: Sorbet sees base_tag
      # as possibly uninitialized in ensure, but its assignment is the first
      # statement and cannot raise.
      remove_image(T.must(base_tag))
    end

    # Build a docker run command for executing a shell command inside the container.
    #
    # @param image_tag    [String]   full image:tag reference
    # @param project_root [Pathname] project root to mount
    # @param shell_cmd    [String]   command to run inside the container
    # @param volumes      [Array<String>] extra "host:container" mounts; host
    #   paths may use ~ (e.g. "~/.dev/engines/unreal-engine-css:/ue")
    # @param env          [Hash{String => String}] env vars to inject (named
    #   on argv, valued in the invocation's env)
    # @return [Invocation] the docker run argv and the env it needs
    sig do
      params(
        image_tag: String,
        project_root: Pathname,
        shell_cmd: String,
        volumes: T::Array[String],
        env: T::Hash[String, String],
      ).returns(Invocation)
    end
    def docker_run_command(image_tag, project_root:, shell_cmd:, volumes: [], env: {})
      container_env = container_env(env)
      argv = [
        *@engine.argv_prefix, "run", "--rm",
        *SIGPENDING_ULIMIT,
        *self.class.label_flags(image_tag, project_root),
        "-v", "#{project_root}:/project",
        *data_root_flags,
        *volume_flags(volumes),
        *env_flags(container_env),
        "-w", "/project",
        image_tag,
        "sh", "-c", shell_cmd,
      ]
      Invocation.new(argv: argv, env: container_env)
    end

    # The container's data root and Linuxbrew prefix (ADR-0008).
    #
    # On a Mac the data root is the container's own: a named volume at its
    # fixed path, filled from the lock by the dev inside (DEV_DATA_ROOT,
    # set by env_flags); nothing of the host's directory is mounted, the
    # VM boundary being the reason. On Linux there is no boundary, so the
    # host's data root *is* the container's (dev#308): bind-mounted at the
    # host's own path, so every absolute path the store embeds reads the
    # same from both sides — one copy, nothing installed twice. The
    # Linuxbrew prefix is a named volume on both — the host user's own on
    # Linux, where the engine is shared (.prefix_volume): the host has no
    # prefix to lend at that path, and bottles refuse a symlinked one.
    # Volumes are created first — `docker volume create` is idempotent — so
    # the first container to mount them finds them initialised from the
    # image.
    #
    # @return [Array<String>] docker `-v` flags
    sig { returns(T::Array[String]) }
    def data_root_flags
      data_root = if @host_os == "linux"
        "#{data_root_mount}:#{data_root_mount}"
      else
        @engine.run(["volume", "create", DATA_ROOT_VOLUME], out: File::NULL)
        "#{DATA_ROOT_VOLUME}:#{DATA_ROOT_MOUNT}"
      end
      @engine.run(["volume", "create", prefix_volume], out: File::NULL)
      ["-v", data_root, "-v", "#{prefix_volume}:#{LINUXBREW_MOUNT}"]
    end

    # Where the container finds its data root: the host's own path on
    # Linux (the bind mount's, override included), the fixed mount point
    # elsewhere.
    #
    # @return [String]
    sig { returns(String) }
    def data_root_mount
      @host_os == "linux" ? Dev::DataRoot.path : DATA_ROOT_MOUNT
    end

    # Env for a container dev creates: the inside marker (see
    # ContainerContext), the data root's container path, then the configured
    # entries. Every container-creation site funnels through here, so no
    # dev-created container can lack either.
    #
    # @param env [Hash{String => String}] run_env entries resolved on the host
    # @return [Hash{String => String}] the container's full env
    sig { params(env: T::Hash[String, String]).returns(T::Hash[String, String]) }
    def container_env(env)
      ContainerContext::MARKER_ENV
        .merge("DEV_DATA_ROOT" => data_root_mount)
        .merge(env)
    end

    # The `-e` flags naming +env+'s variables — names only. docker fills a
    # valueless `-e NAME` from the client process's environment, which is
    # where the caller puts the values (Invocation); the argv, which any
    # user on the host can read, never carries one.
    #
    # @param env [Hash{String => String}]
    # @return [Array<String>] docker `-e NAME` flags
    sig { params(env: T::Hash[String, String]).returns(T::Array[String]) }
    def env_flags(env)
      env.keys.flat_map { |name| ["-e", name] }
    end

    # "host:container" volume specs -> docker `-v` flags, expanding ~ in the host
    # path (e.g. "~/.dev/engines/...:/ue"). Every `-v` composition site funnels
    # through here, so this is where the local-mounts capability is enforced.
    #
    # @param volumes [Array<String>]
    # @return [Array<String>]
    # @raise [LocalMountsUnsupportedError] when the engine cannot see local paths
    sig { params(volumes: T::Array[String]).returns(T::Array[String]) }
    def volume_flags(volumes)
      assert_local_mounts!
      volumes.flat_map do |spec|
        host, container = spec.split(":", 2)
        ["-v", "#{Dev::DataRoot.expand(T.must(host))}:#{container}"]
      end
    end

    # --- persistent service container (build.container.persist) ----------

    # Ensure the long-lived service container for image_tag exists and is running,
    # reaping any container left from a previous image tag of the same project.
    # Idempotent: a no-op when the right container is already up.
    #
    # The container idles on `sleep infinity` so commands run against it via
    # `docker exec` (see docker_exec_command). Its writable layer — and thus an
    # incremental build tool's state written on top of the image — survives
    # between commands, which a fresh `docker run --rm` would discard.
    #
    # @param image_tag    [String]   full image:tag the container runs
    # @param project_root [Pathname] bind-mounted at /project
    # @param volumes      [Array<String>] extra "host:container" mounts (e.g. engine)
    # @return [String] the running container's name
    sig { params(image_tag: String, project_root: Pathname, volumes: T::Array[String]).returns(String) }
    def ensure_service!(image_tag, project_root:, volumes: [])
      name = self.class.service_container_name(image_tag, project_root)
      reap_stale_services!(image_tag, project_root)

      exists = container_exists?(name)
      if exists && on_another_prefix_volume?(name)
        # Mounts are fixed at creation: a container from before the per-user
        # split (or another user's checkout at this path) mounts a prefix
        # volume that is not this user's; reused, this user's aligner would
        # hand that shared volume over and the other user's hand it back.
        remove_container(name)
        exists = false
      end

      if exists
        start_container(name) unless container_running?(name)
      else
        create_service_container(name, image_tag, project_root:, volumes:)
      end
      name
    end

    # The Linuxbrew prefix volume this host user's containers mount.
    #
    # @return [String]
    sig { returns(String) }
    def prefix_volume = BuildContainer.prefix_volume(host_os: @host_os, host_user: @host_user)

    # The volume a container has mounted at the Linuxbrew prefix.
    #
    # @param name [String] the container
    # @return [String, nil] nil when inspect reports none (or fails)
    sig { params(name: String).returns(T.nilable(String)) }
    def container_prefix_volume(name)
      template = "{{range .Mounts}}{{if eq .Destination \"#{LINUXBREW_MOUNT}\"}}{{.Name}}{{end}}{{end}}"
      mounted = @engine.capture(["container", "inspect", "-f", template, name]).strip
      mounted.empty? ? nil : mounted
    end

    # Run +blk+ against a one-shot sibling of the service container: the
    # same image, mounts, labels and marker, under a name of its own, created
    # `--rm` and removed when the block ends however it ends. The run
    # topology of `dev up --no-cache`: the persistent container — its warm
    # data root mounted at creation — is never touched, and whatever the
    # block installs into the container's writable layer goes with it.
    #
    # @param image_tag    [String]   full image:tag the container runs
    # @param project_root [Pathname] bind-mounted at /project
    # @param volumes      [Array<String>] extra "host:container" mounts (e.g. engine)
    # @yieldparam name [String] the running container's name
    # @return [void]
    sig do
      params(
        image_tag: String,
        project_root: Pathname,
        volumes: T::Array[String],
        blk: T.proc.params(name: String).void,
      ).void
    end
    def with_one_shot_container(image_tag, project_root:, volumes: [], &blk)
      name = "#{self.class.service_container_name(image_tag, project_root)}-cold-#{SecureRandom.hex(4)}"
      create_service_container(name, image_tag, project_root:, volumes:, one_shot: true)
      begin
        blk.call(name)
      ensure
        remove_container(name)
      end
    end

    # Build a `docker exec` command running shell_cmd inside the service container,
    # mirroring docker_run_command's working dir (/project) and `-e` env handling.
    # The marker and data root are the container's since its creation, so
    # only the per-command env is named here.
    #
    # @param container [String] running container name
    # @param shell_cmd [String]
    # @param env       [Hash{String => String}] env vars to inject (named
    #   on argv, valued in the invocation's env)
    # @return [Invocation] the docker exec argv and the env it needs
    sig do
      params(
        container: String,
        shell_cmd: String,
        env: T::Hash[String, String],
      ).returns(Invocation)
    end
    def docker_exec_command(container, shell_cmd:, env: {})
      argv = [*@engine.argv_prefix, "exec", *env_flags(env), "-w", "/project", container, "sh", "-c", shell_cmd]
      Invocation.new(argv: argv, env: env)
    end

    # Remove every container for this checkout — the current tag's and any
    # stale one — backing `dev container reset`. Keyed by the workspace label
    # (not the tag) so a container from a now-superseded Dockerfile/dep is
    # still matched, while OTHER checkouts' containers are left untouched.
    #
    # @param project_root [Pathname] the checkout whose containers to remove
    # @return [Array<String>] names of the removed containers
    sig { params(project_root: Pathname).returns(T::Array[String]) }
    def reset_service!(project_root)
      names = service_containers(project_root).map(&:name)
      names.each { |name| remove_container(name) }
      names
    end

    # Stop this checkout's running containers, keeping them — their writable
    # layer (the build tool's incremental state) is the whole point of
    # `persist`, and `ensure_service!` restarts a stopped one warm. Backs
    # `dev container down`. `-t 0`: PID 1 is `sleep infinity`, which ignores
    # SIGTERM, so docker's grace period would only add the wait.
    #
    # @param project_root [Pathname] the checkout whose containers to stop
    # @return [Array<String>] names of the containers stopped
    # @raise [StopFailedError] when docker cannot stop one
    sig { params(project_root: Pathname).returns(T::Array[String]) }
    def stop_service!(project_root)
      names = service_containers(project_root).select(&:running).map(&:name)
      names.each do |name|
        next if @engine.run(["stop", "-t", "0", name], out: File::NULL, err: File::NULL)

        raise StopFailedError, "could not stop container #{name}."
      end
      names
    end

    # The facts `dev container status` renders; probes only, nothing changes.
    #
    # The registry probe runs inside a login session when the registry is
    # named (a pinned image's private registry, dev#313) — outside one, a
    # private registry answers 401 and the image looks unpublished. A host
    # with no credential to log in with gets the local half and nil for the
    # registry's: unknown, not absent.
    #
    # @param image_tag    [String]   the tag the checkout resolves to today
    # @param project_root [Pathname]
    # @param registry     [String, nil] the registry host to log in to around
    #   the probe; nil probes bare (the deprecated Dockerfile image's public registry)
    # @return [ServiceStatus]
    sig { params(image_tag: String, project_root: Pathname, registry: T.nilable(String)).returns(ServiceStatus) }
    def service_status(image_tag, project_root, registry: nil)
      ServiceStatus.new(
        image_tag: image_tag,
        local_image: local_image?(image_tag),
        in_registry: registry ? registry_has_in_session?(registry, image_tag) : registry_has?(image_tag),
        current_container_name: self.class.service_container_name(image_tag, project_root),
        containers: image_containers(image_tag, project_root),
      )
    end

    # Run the prewarm command in a container off the base image and commit the
    # result to final_tag. Build-dep volumes (e.g. the engine) are mounted with
    # `-v`; secrets are written to host temp files and bind-mounted at
    # /run/secrets/<id> (a bind mount, so the value is never captured by
    # `docker commit`, which only persists the container's writable layer).
    # Secrets are deliberately NOT passed via `-e`, since `docker commit` would
    # bake run-time env into the committed image config.
    #
    # @param base_tag  [String]
    # @param final_tag [String]
    # @param volumes   [Array<String>] "host:container" build-dep mounts, as configured
    # @param prewarm   [String] shell command run via `sh -c`
    # @param secrets   [Hash{String => String}] secret id => value
    sig do
      params(
        base_tag: String,
        final_tag: String,
        volumes: T::Array[String],
        prewarm: String,
        secrets: T::Hash[String, String],
      ).void
    end
    def prewarm_commit!(base_tag, final_tag, volumes:, prewarm:, secrets:)
      container = prewarm_container_name
      secret_files = write_secret_files(secrets)
      secret_mounts = secret_files.flat_map { |id, path| ["-v", "#{path}:/run/secrets/#{id}:ro"] }

      run_argv = [
        *@engine.argv_prefix, "run", "--name", container,
        *SIGPENDING_ULIMIT,
        *volume_flags(volumes),
        *secret_mounts,
        base_tag,
        "sh", "-c", prewarm,
      ]

      raise "Prewarm run failed for #{final_tag}" unless run_watched(run_argv, container: container)
      raise "docker commit failed for #{final_tag}" unless @engine.run(["commit", container, final_tag])
    ensure
      # T.must: Sorbet sees container as possibly uninitialized in ensure, but
      # its assignment is the first statement and cannot raise.
      @engine.run(["rm", "-f", T.must(container)], out: File::NULL, err: File::NULL)
      secret_files&.each_value { |path| File.delete(path) if File.exist?(path) }
    end

    # Run the prewarm docker command under the hung-build watcher, which detects
    # the Rosetta clang deadlock (silent, idle container) and retries transient
    # crashes while failing fast on real compile errors. Isolated here so callers
    # (and tests) treat it as a single boundary.
    #
    # @param argv      [Array<String>] docker run command
    # @param container [String] the run's --name, so a stall can be killed
    # @return [Boolean] whether a run succeeded within the retry budget
    sig { params(argv: T::Array[String], container: String).returns(T::Boolean) }
    def run_watched(argv, container:)
      BuildWatcher.new(container_name: container, engine: @engine).run(argv)
    end

    # Write each secret value to a private host temp file for bind-mounting into
    # the prewarm container. Returns {id => path}; caller deletes the files.
    #
    # The files live under the data root, NOT Dir.tmpdir: on macOS + colima the
    # VM shares $HOME and /Users/Shared but not /var/folders, and docker turns a
    # bind mount from an unshared host path into an empty directory — the
    # prewarm then reads an empty secret and fails far from the cause.
    #
    # @param secrets [Hash{String => String}]
    # @return [Hash{String => String}] secret id => temp file path
    # @raise [SecretDirCompromisedError] when the per-uid dir fails verification
    sig { params(secrets: T::Hash[String, String]).returns(T::Hash[String, String]) }
    def write_secret_files(secrets)
      dir = secrets_dir
      sweep_stale_secrets(dir)
      secrets.each_with_object({}) do |(id, value), files|
        path = File.join(dir, "dev-secret-#{SecureRandom.hex(8)}")
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(value) }
        files[id] = path
      end
    end

    # The per-identity secrets dir under the data root: secrets-<uid>, 0700,
    # verified before use. Per-uid rather than a shared sticky-1777 dir because
    # a shared dir's owner can unlink and replace anyone's files (sticky only
    # stops non-owners) — a secret-substitution vector between file write and
    # bind mount. Verification guards the unprovisioned-machine case: the data
    # root's parent (/Users/Shared) ships world-writable, so any local user can
    # pre-own the tree before provisioning; a pre-existing entry here is
    # attacker-suspect until lstat proves it a real directory we own. The dir
    # sits directly under the data root (not a shared tmp/) so no world-writable
    # parent can rename a verified dir out from under us post-check.
    #
    # @return [String] verified dir path
    # @raise [SecretDirCompromisedError]
    sig { returns(String) }
    def secrets_dir
      dir = File.join(Dev::DataRoot.path, "secrets-#{Process.uid}")
      begin
        Dir.mkdir(dir, 0o700)
      rescue Errno::EEXIST
        # Pre-existing entry: verified below like everything else.
      end
      st = File.lstat(dir)
      unless st.directory? && st.uid == Process.uid
        raise SecretDirCompromisedError,
          "#{dir} is not a directory owned by uid #{Process.uid} " \
          "(found #{st.directory? ? "dir" : "non-dir"} owned by uid #{st.uid}). " \
          "Refusing to write secrets there — remove it and re-run."
      end
      # Ours, but normalize the mode (a setgid data root propagates g+s on
      # Linux; older dev versions never created this dir, so no legacy modes).
      File.chmod(0o700, dir) if (st.mode & 0o7777) != 0o700
      dir
    end

    # Delete day-old dev-secret-* leftovers. The caller's ensure covers normal
    # failures, but SIGKILL strands 0600 files under the data root, which —
    # unlike /var/folders — macOS never purges. A day's grace keeps concurrent
    # runs' live files safe (they exist for minutes, not hours).
    #
    # @param dir [String] the verified per-uid secrets dir
    sig { params(dir: String).void }
    def sweep_stale_secrets(dir)
      Dir.glob(File.join(dir, "dev-secret-*")).each do |path|
        File.delete(path) if Time.now - File.mtime(path) > 86_400
      rescue Errno::ENOENT
        # A concurrent sweep won the race; the file is gone either way.
      end
    end

    # --- internal helpers ------------------------------------------------

    # Unique name for the throwaway prewarm container; pid + random suffix so
    # concurrent dev invocations never collide.
    sig { returns(String) }
    def prewarm_container_name
      "dev-prewarm-#{Process.pid}-#{rand(1_000_000)}"
    end

    sig { params(image_tag: String).void }
    def remove_image(image_tag)
      @engine.run(["image", "rm", "-f", image_tag], out: File::NULL, err: File::NULL)
    end

    # Remove service containers for this checkout that don't match the current
    # tag's name, so a Dockerfile/dep bump (new tag) doesn't leave the old one
    # running alongside the new. Scoped to the workspace label, so a tag bump in
    # one checkout never reaps another checkout's container.
    sig { params(image_tag: String, project_root: Pathname).void }
    def reap_stale_services!(image_tag, project_root)
      keep = self.class.service_container_name(image_tag, project_root)
      image_containers(image_tag, project_root).each do |container|
        remove_container(container.name) unless container.name == keep
      end
    end

    # This image's containers in the checkout, running or stopped, at any
    # tag: the workspace's containers under the image's name prefix
    # (service_container_prefix).
    #
    # @param image_tag    [String]
    # @param project_root [Pathname]
    # @return [Array<ServiceContainer>] in docker's order
    sig { params(image_tag: String, project_root: Pathname).returns(T::Array[ServiceContainer]) }
    def image_containers(image_tag, project_root)
      prefix = self.class.service_container_prefix(image_tag, project_root)
      service_containers(project_root).select { |container| container.name.start_with?(prefix) }
    end

    # The registry probe from inside a read-scope login session; nil when
    # the host has no credential to open one with.
    #
    # @param registry  [String] the registry host
    # @param image_tag [String]
    # @return [Boolean, nil]
    sig { params(registry: String, image_tag: String).returns(T.nilable(T::Boolean)) }
    def registry_has_in_session?(registry, image_tag)
      @registry_login.with(registry) { registry_has?(image_tag) }
    rescue GhAuth::NotAuthenticatedError, GhAuth::MissingScopeError, GhAuth::GhMissingError,
           RegistryLogin::LoginFailedError
      nil
    end

    # This checkout's containers, running or stopped, by the workspace label —
    # the key the label contract exists for. One `docker ps` per call.
    #
    # @param project_root [Pathname]
    # @return [Array<ServiceContainer>] in docker's order
    sig { params(project_root: Pathname).returns(T::Array[ServiceContainer]) }
    def service_containers(project_root)
      out = @engine.capture([
        "ps", "-a",
        "--filter", "label=#{WORKSPACE_LABEL}=#{self.class.workspace_id(project_root)}",
        "--format", "{{.Names}}\t{{.State}}",
      ])
      out.split("\n").map(&:strip).reject(&:empty?).map do |line|
        name, state = line.split("\t", 2)
        ServiceContainer.new(name: T.must(name), running: state == "running", prefix_volume: container_prefix_volume(T.must(name)))
      end
    end

    # Whether a container mounts a prefix volume other than this user's. An
    # unknown mount (inspect answered nothing) is not a reason to drop a
    # warm container.
    #
    # @param name [String]
    # @return [Boolean]
    sig { params(name: String).returns(T::Boolean) }
    def on_another_prefix_volume?(name)
      mounted = container_prefix_volume(name)
      !mounted.nil? && mounted != prefix_volume
    end

    sig { params(name: String).returns(T::Boolean) }
    def container_exists?(name)
      @engine.run(["container", "inspect", name], out: File::NULL, err: File::NULL)
    end

    sig { params(name: String).returns(T::Boolean) }
    def container_running?(name)
      @engine.capture(["container", "inspect", "-f", "{{.State.Running}}", name]).strip == "true"
    end

    sig { params(name: String).void }
    def start_container(name)
      @engine.run(["start", name], out: File::NULL, err: File::NULL)
    end

    # Create the detached, idle service container: the project at /project, any
    # extra volumes (e.g. the engine), the label contract, the inside marker
    # (inherited by every `docker exec`), and `sleep infinity` so it stays up.
    #
    # @param one_shot [Boolean] `--rm`: the container goes when it stops
    sig do
      params(name: String, image_tag: String, project_root: Pathname, volumes: T::Array[String], one_shot: T::Boolean).void
    end
    def create_service_container(name, image_tag, project_root:, volumes: [], one_shot: false)
      env = container_env({})
      args = [
        "run", "-d", *(one_shot ? ["--rm"] : []), "--name", name,
        *self.class.label_flags(image_tag, project_root),
        "-v", "#{project_root}:/project",
        *data_root_flags,
        *volume_flags(volumes),
        *env_flags(env),
        "-w", "/project",
        image_tag,
        "sleep", "infinity",
      ]
      success = @engine.run(args, env: env, out: File::NULL, err: File::NULL)
      raise "Failed to create service container #{name}" unless success
    end

    sig { params(name: String).void }
    def remove_container(name)
      @engine.run(["rm", "-f", name], out: File::NULL, err: File::NULL)
    end

    sig { params(image_tag: String).returns(T::Boolean) }
    def local_image?(image_tag)
      @engine.run(["image", "inspect", image_tag], out: File::NULL, err: File::NULL)
    end

    # Stream pull progress to stdout so a multi-GB pull (e.g. a 20GB build image
    # on a fresh CI runner) shows layer-by-layer liveness instead of looking hung.
    # stderr stays silenced: the pull doubles as a cache probe, so "manifest not
    # found" on a miss is expected noise, not an error worth surfacing.
    sig { params(image_tag: String).returns(T::Boolean) }
    def pull(image_tag)
      @engine.run(["pull", image_tag], err: File::NULL)
    end

    # Build the image with BuildKit. secrets are passed as `--secret
    # id=NAME,env=NAME` with the value exported into docker's environment for
    # that invocation, so the value is mounted only for the requesting RUN and
    # never persists in a layer. Nothing from the data root enters the build:
    # a lock is not an image input (ADR-0008).
    #
    # @param image_tag      [String]
    # @param project_root   [Pathname]
    # @param build_args     [Hash{String => String}]
    # @param secrets        [Hash{String => String}] secret id => value
    sig do
      params(
        image_tag: String,
        project_root: Pathname,
        build_args: T::Hash[String, String],
        secrets: T::Hash[String, String],
      ).void
    end
    def build!(image_tag, project_root:, build_args: {}, secrets: {})
      arg_flags = build_args.flat_map { |name, value| ["--build-arg", "#{name}=#{value}"] }
      secret_flags = secrets.keys.flat_map { |id| ["--secret", "id=#{id},env=#{id}"] }

      # BuildKit is required for --secret; enable it explicitly
      # so the build behaves the same regardless of the host Docker default. Secret
      # values travel via the environment (referenced by env=), never on argv.
      env = { "DOCKER_BUILDKIT" => "1" }.merge(secrets)

      # --progress=plain: BuildKit's auto renderer detects non-TTY stdout (CI log
      # pipes) and goes near-silent, so a long image build (msvc-wine download,
      # WineHQ install) looks hung for tens of minutes. Plain progress prints every
      # step with timestamps and streams RUN output, giving CI logs a heartbeat.
      args = [
        "build", "--progress=plain", "-t", image_tag,
        *arg_flags, *secret_flags,
        project_root.to_s,
      ]
      success = @engine.run(args, env: env)
      raise BuildFailedError, "Docker build failed for #{image_tag}" unless success
    end

    # Stream push progress for the same liveness reason as pull: publishing a
    # multi-GB image can take many minutes and CI logs need a heartbeat.
    sig { params(image_tag: String).returns(T::Boolean) }
    def push!(image_tag)
      @engine.run(["push", image_tag])
    end

    # Guarantee the shared registry advertises this content tag, so other
    # machines pull it instead of rebuilding. A no-op when the registry already
    # has the tag (checked via a remote manifest lookup that transfers only
    # metadata, never the multi-GB layers), otherwise pushes the local image.
    #
    # Best-effort: a push failure is logged, not raised, so a transient registry
    # hiccup never fails an otherwise-green build — the next provisioning run
    # retries, since the registry still lacks the tag.
    #
    # @param image_tag [String]
    # @return [Boolean] whether the registry has the tag after this call
    sig { params(image_tag: String).returns(T::Boolean) }
    def publish!(image_tag)
      if registry_has?(image_tag)
        $stderr.puts "dev: Container image already published — #{image_tag}"
        return true
      end

      $stderr.puts "dev: Publishing container image to registry — #{image_tag}"
      pushed = push!(image_tag)
      $stderr.puts "dev: WARNING — could not publish #{image_tag} to the registry" unless pushed
      pushed
    end

    # Whether the registry already advertises image_tag. `docker manifest inspect`
    # queries the remote registry for the tag's manifest only (no layer
    # download), so this is a cheap existence check.
    #
    # @param image_tag [String]
    # @return [Boolean]
    sig { params(image_tag: String).returns(T::Boolean) }
    def registry_has?(image_tag)
      @engine.run(["manifest", "inspect", image_tag], out: File::NULL, err: File::NULL)
    end

    private

    # @raise [LocalMountsUnsupportedError] when the engine's daemon cannot see
    #   the local paths a bind-mount would reference
    sig { void }
    def assert_local_mounts!
      return if @engine.local_mounts?

      raise LocalMountsUnsupportedError,
        "the resolved container engine (#{@engine.kind}) cannot bind-mount local paths — " \
        "a remote engine needs its sync strategy before dev can mount workspaces into it."
    end
  end
end
