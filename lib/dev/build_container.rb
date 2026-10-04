# typed: strict
# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "securerandom"
require "yaml"

require "dev/build_watcher"
require "dev/container_context"
require "dev/container_engine"
require "dev/data_root"
require "dev/deps/local_store"
require "dev/deps/lockfile"
require "dev/engine_resources_check"

module Dev
  # Content-addressed Docker image management for build containers.
  #
  # Computes a tag from the hash of Dockerfile + .dockerignore + lockfiles
  # (deps.lock, build-deps.lock) plus any project-declared content globs. Any
  # change to those inputs produces a new tag, guaranteeing a rebuild.
  #
  # Every docker invocation rides an injected Dev::ContainerEngine (the
  # per-user container substrate — see that class), so which daemon serves a
  # build is a provisioning decision, never an assumption here. Pure tag and
  # name computation stays on the class (no engine, no side effects).
  #
  # Usage:
  #   BuildContainer.new(engine:).ensure_image!(config, project_root: Pathname("..."))
  #     # pulls or builds the image, returns the full image:tag string
  #
  #   BuildContainer.content_tag(project_root: Pathname("..."))
  #     # returns the content-addressed tag without side effects
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
    end

    # What `dev container status` renders: image presence on both sides and
    # this checkout's containers, the current tag's one named so stale
    # siblings (reaped on the next `up`) can be told apart.
    class ServiceStatus < T::Struct
      const :image_tag, String
      const :local_image, T::Boolean
      const :in_registry, T::Boolean
      const :current_container_name, String
      const :containers, T::Array[ServiceContainer]
    end

    # Always-hashed inputs. deps.lock (app/test deps, e.g. SML) and build-deps.lock
    # (build deps, e.g. the engine) join the Dockerfile so a dependency bump
    # invalidates a prewarmed image. Missing files are skipped (see content_tag).
    CONTENT_FILES = ["Dockerfile", ".dockerignore", "deps.lock", "build-deps.lock"].freeze
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

    # Where the host's data root is bind-mounted in every container dev
    # creates. Fixed, because what the store holds embeds absolute paths
    # (venvs, binstubs), and FHS-conventional for a program's variable state.
    DATA_ROOT_MOUNT = "/var/lib/dev"

    # @return [Dev::ContainerEngine] the engine every docker invocation rides
    sig { returns(Dev::ContainerEngine) }
    attr_reader :engine

    # @param engine [Dev::ContainerEngine] resolved for the invoking user
    # @param resources_check [Dev::EngineResourcesCheck] the engine-vs-hint
    #   gate every image resolution passes through first
    sig { params(engine: Dev::ContainerEngine, resources_check: Dev::EngineResourcesCheck).void }
    def initialize(engine:, resources_check: Dev::EngineResourcesCheck.new)
      @engine = engine
      @resources_check = resources_check
    end

    class << self
      extend T::Sig

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

      # Full image reference with content-addressed tag.
      #
      # @param config       [Dev::BuildContainerConfig]
      # @param project_root [Pathname]
      # @return [String] e.g. "jpduchesne89/snappy-linux:content-a1b2c3d4e5f6"
      sig { params(config: Dev::BuildContainerConfig, project_root: Pathname).returns(String) }
      def image_with_tag(config, project_root:)
        globs = config.respond_to?(:content_globs) ? config.content_globs : []
        structure_globs = config.respond_to?(:structure_globs) ? config.structure_globs : []
        "#{config.image_ref}:#{content_tag(project_root:, extra_globs: globs, structure_globs:)}"
      end

      # Named build-contexts derived from build-deps.lock: every build-group
      # dependency with an install_dir becomes "<dep-name>=<expanded host path>".
      # The context name is lowercased because Docker rejects uppercase build-context
      # names ("invalid reference format"); the Dockerfile references the lowercased
      # name (e.g. `--mount=from=unrealengine`). Returns {} when the lockfile is
      # absent or has no such deps.
      #
      # @param project_root [Pathname]
      # @param store [Dev::Deps::ArtifactStore] where the locked trees are published
      # @return [Hash{String => String}] context name => absolute host path
      sig do
        params(project_root: Pathname, store: Dev::Deps::ArtifactStore).returns(T::Hash[String, String])
      end
      def build_contexts_from_lockfile(project_root, store: Dev::Deps::LocalStore.new)
        contexts = {}
        locked_deps(project_root).each do |dep|
          # Env-scoped deps are not whole-image build inputs; group == :build
          # limits us to build-deps.lock entries.
          next unless dep.group == :build
          next if dep.metadata&.key?("env")

          install_dir = dep.metadata&.fetch("install_dir", nil)
          next unless install_dir

          # The store's path for the locked version, so the build context
          # tracks exactly what the integration published (see
          # resolve_versioned_volumes); a version-less entry is its bare base.
          contexts[dep.name.downcase] =
            if dep.version
              store.tree_path(Dev::Deps::TreeKey.new(base: install_dir, version: dep.version.to_s)).to_s
            else
              Dev::DataRoot.expand(install_dir)
            end
        end
        contexts
      end

      # Rewrite each "host:container[:opts]" volume whose host path is a locked
      # dependency's install_dir to the store's path for the locked version (the
      # immutable tree the integration published). This is how a command mounts
      # the exact locked version while the store keeps every version side by
      # side. Volumes that don't match a locked install_dir (e.g. the shared
      # cache mount) pass through unchanged.
      #
      # @param volumes      [Array<String>] configured "host:container[:opts]" specs
      # @param project_root [Pathname]
      # @param store        [Dev::Deps::ArtifactStore] where the locked trees are published
      # @return [Array<String>] specs with matching host paths version-resolved
      sig do
        params(
          volumes: T::Array[String],
          project_root: Pathname,
          store: Dev::Deps::ArtifactStore,
        ).returns(T::Array[String])
      end
      def resolve_versioned_volumes(volumes, project_root:, store: Dev::Deps::LocalStore.new)
        keys = locked_tree_keys(project_root)
        return volumes if keys.empty?

        volumes.map do |spec|
          host, container = spec.split(":", 2)
          key = keys[Dev::DataRoot.expand(T.must(host))]
          key ? "#{store.tree_path(key)}:#{container}" : spec
        end
      end

      # Map every locked dependency install_dir (expanded) to its locked version,
      # scanning both lockfiles (including env-nested build deps). Only entries with
      # BOTH an install_dir and a version contribute.
      #
      # @param project_root [Pathname]
      # @return [Hash{String => String}] expanded install_dir => version
      sig { params(project_root: Pathname).returns(T::Hash[String, String]) }
      def install_dir_versions(project_root)
        locked_tree_keys(project_root).transform_values(&:version)
      end

      # The store key of every locked dependency that has both an install_dir
      # and a version, by its expanded install_dir — the spelling a configured
      # volume's host path normalizes to for matching.
      #
      # @param project_root [Pathname]
      # @return [Hash{String => Dev::Deps::TreeKey}] expanded install_dir => key
      sig { params(project_root: Pathname).returns(T::Hash[String, Dev::Deps::TreeKey]) }
      def locked_tree_keys(project_root)
        locked_deps(project_root).each_with_object({}) do |dep, acc|
          install_dir = dep.metadata&.fetch("install_dir", nil)
          next unless install_dir && dep.version

          acc[Dev::DataRoot.expand(install_dir)] = Dev::Deps::TreeKey.new(base: install_dir, version: dep.version.to_s)
        end
      end

      # All locked dependencies from both lockfiles, parsed by Lockfile so
      # format knowledge (including the legacy flat format) lives in one place.
      #
      # @param project_root [Pathname]
      # @return [Array<Dev::Deps::Dependency>]
      sig { params(project_root: Pathname).returns(T::Array[Dev::Deps::Dependency]) }
      def locked_deps(project_root)
        Dev::Deps::Lockfile.new(dir: project_root).read
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
        image = image_basename(image_tag)
        tag = T.must(image_tag.split(":").last)
        "dev-#{sanitize_container_name(image)}-#{workspace_id(project_root)}-#{sanitize_container_name(tag)}"
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

    # Ensure the build container image exists: use a local image if present,
    # pull from registry if available, otherwise build. Returns the full
    # image:tag string.
    #
    # The local check comes first so images built manually are honored.
    #
    # build_args_provider / secrets_provider are lazy sources of docker
    # --build-arg and BuildKit --secret values (e.g. credentials). They are only
    # called on a cache miss so cache hits never trigger credential resolution or
    # prompts.
    #
    # On a cache miss, every `group: build` dependency in build-deps.lock that
    # declares an install_dir is passed as a BuildKit named build-context (keyed
    # by dependency name), so the Dockerfile can bind-mount large host artifacts
    # (e.g. the engine) without baking them into the image.
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
    #
    # Before any image work, the engine is measured against the config's
    # resources hint (EngineResourcesCheck) — read-only; `dev up` is the one
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
      ).returns(String)
    end
    def ensure_image!(config, project_root:, push: true, publish: false,
                      build_args_provider: nil, secrets_provider: nil)
      @resources_check.check!(engine: @engine, hint: config.resources)
      tag = self.class.image_with_tag(config, project_root:)

      if local_image?(tag)
        $stderr.puts "dev: Container image found locally — #{tag}"
        publish!(tag) if publish
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
        build_contexts = self.class.build_contexts_from_lockfile(project_root)
        build!(tag, project_root:, build_args:, build_contexts:, secrets:)
      end

      push!(tag) if push
      publish!(tag) if publish
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
      # The base is engine-free and secret-free: no build-contexts, no BuildKit
      # secrets. Those are supplied to the prewarm run, not the Dockerfile.
      build!(base_tag, project_root:, build_args:, build_contexts: {}, secrets: {})
      volumes = self.class.resolve_versioned_volumes(config.volumes, project_root:)
      prewarm_commit!(base_tag, tag, volumes:, prewarm:, secrets:)
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
    # @param env          [Hash{String => String}] env vars to inject via `-e`
    # @return [Array<String>] docker run command array
    sig do
      params(
        image_tag: String,
        project_root: Pathname,
        shell_cmd: String,
        volumes: T::Array[String],
        env: T::Hash[String, String],
      ).returns(T::Array[String])
    end
    def docker_run_command(image_tag, project_root:, shell_cmd:, volumes: [], env: {})
      [
        *@engine.argv_prefix, "run", "--rm",
        *SIGPENDING_ULIMIT,
        *self.class.label_flags(image_tag, project_root),
        "-v", "#{project_root}:/project",
        *data_root_flags,
        *volume_flags(volumes),
        *env_flags(env),
        "-w", "/project",
        image_tag,
        "sh", "-c", shell_cmd,
      ]
    end

    # The host's data root bind-mounted at its fixed container path, so the
    # dev inside (DEV_DATA_ROOT, set by env_flags) shares one artifact store
    # with the host. Created first when missing: docker would otherwise create
    # it root-owned and the host's dev could never write it.
    #
    # @return [Array<String>] docker `-v` flags
    sig { returns(T::Array[String]) }
    def data_root_flags
      root = Dev::DataRoot.path
      FileUtils.mkdir_p(root)
      ["-v", "#{root}:#{DATA_ROOT_MOUNT}"]
    end

    # Env for a container dev creates: the inside marker (see
    # ContainerContext), the data root's container path, then the configured
    # entries. Every container-creation site funnels through here, so no
    # dev-created container can lack either.
    #
    # @param env [Hash{String => String}] run_env entries resolved on the host
    # @return [Array<String>] docker `-e` flags
    sig { params(env: T::Hash[String, String]).returns(T::Array[String]) }
    def env_flags(env)
      ContainerContext::MARKER_ENV
        .merge("DEV_DATA_ROOT" => DATA_ROOT_MOUNT)
        .merge(env)
        .flat_map { |name, value| ["-e", "#{name}=#{value}"] }
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

      if container_exists?(name)
        start_container(name) unless container_running?(name)
      else
        create_service_container(name, image_tag, project_root:, volumes:)
      end
      name
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
    #
    # @param container [String] running container name
    # @param shell_cmd [String]
    # @param env       [Hash{String => String}] env vars to inject via `-e`
    # @return [Array<String>] docker exec command array
    sig do
      params(
        container: String,
        shell_cmd: String,
        env: T::Hash[String, String],
      ).returns(T::Array[String])
    end
    def docker_exec_command(container, shell_cmd:, env: {})
      env_flags = env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }
      [*@engine.argv_prefix, "exec", *env_flags, "-w", "/project", container, "sh", "-c", shell_cmd]
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
    # @param image_tag    [String]   the tag the checkout resolves to today
    # @param project_root [Pathname]
    # @return [ServiceStatus]
    sig { params(image_tag: String, project_root: Pathname).returns(ServiceStatus) }
    def service_status(image_tag, project_root)
      ServiceStatus.new(
        image_tag: image_tag,
        local_image: local_image?(image_tag),
        in_registry: registry_has?(image_tag),
        current_container_name: self.class.service_container_name(image_tag, project_root),
        containers: service_containers(project_root),
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
    # @param volumes   [Array<String>] resolved "host:container" build-dep mounts
    #   (already version-resolved by the caller via resolve_versioned_volumes)
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
      service_containers(project_root).each do |container|
        remove_container(container.name) unless container.name == keep
      end
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
        ServiceContainer.new(name: T.must(name), running: state == "running")
      end
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
      args = [
        "run", "-d", *(one_shot ? ["--rm"] : []), "--name", name,
        *self.class.label_flags(image_tag, project_root),
        "-v", "#{project_root}:/project",
        *data_root_flags,
        *volume_flags(volumes),
        *env_flags({}),
        "-w", "/project",
        image_tag,
        "sleep", "infinity",
      ]
      success = @engine.run(args, out: File::NULL, err: File::NULL)
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

    # Build the image with BuildKit. build_contexts are passed as
    # `--build-context name=path` (host artifacts bind-mounted at build time,
    # never stored in the image). secrets are passed as `--secret id=NAME,env=NAME`
    # with the value exported into docker's environment for that invocation, so the
    # value is mounted only for the requesting RUN and never persists in a layer.
    #
    # @param image_tag      [String]
    # @param project_root   [Pathname]
    # @param build_args     [Hash{String => String}]
    # @param build_contexts [Hash{String => String}] context name => host path
    # @param secrets        [Hash{String => String}] secret id => value
    sig do
      params(
        image_tag: String,
        project_root: Pathname,
        build_args: T::Hash[String, String],
        build_contexts: T::Hash[String, String],
        secrets: T::Hash[String, String],
      ).void
    end
    def build!(image_tag, project_root:, build_args: {}, build_contexts: {}, secrets: {})
      arg_flags = build_args.flat_map { |name, value| ["--build-arg", "#{name}=#{value}"] }
      context_flags = build_contexts.flat_map { |name, path| ["--build-context", "#{name}=#{path}"] }
      secret_flags = secrets.keys.flat_map { |id| ["--secret", "id=#{id},env=#{id}"] }

      # BuildKit is required for --build-context and --secret; enable it explicitly
      # so the build behaves the same regardless of the host Docker default. Secret
      # values travel via the environment (referenced by env=), never on argv.
      env = { "DOCKER_BUILDKIT" => "1" }.merge(secrets)

      # --progress=plain: BuildKit's auto renderer detects non-TTY stdout (CI log
      # pipes) and goes near-silent, so a long image build (msvc-wine download,
      # WineHQ install) looks hung for tens of minutes. Plain progress prints every
      # step with timestamps and streams RUN output, giving CI logs a heartbeat.
      args = [
        "build", "--progress=plain", "-t", image_tag,
        *arg_flags, *context_flags, *secret_flags,
        project_root.to_s,
      ]
      success = @engine.run(args, env: env)
      raise "Docker build failed for #{image_tag}" unless success
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
