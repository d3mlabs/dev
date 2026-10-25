# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for the build.container block in dev.yml.
  #
  # When present, commands run inside a Docker container by default. The
  # image is the project's `image` pin in deps.lock (dev#277,
  # Dev::EnvironmentImage); this block shapes the container around it.
  #
  # dev.yml example:
  #   build:
  #     container:
  #       persist: true
  #       volumes:
  #         - "~/.dev/engines/unreal-engine-css:/ue"
  #         - "~/.dev/wwise:/var/cache/dev/wwise-cli:ro"
  #       run_env:
  #         STAGING_DEPLOY_KEY: staging/deploy_key
  #       resources:
  #         cpus: 12
  #         memory_gib: 24
  #
  # Deprecated (d3mlabs/dev#311): `image`/`registry` name a hand-written
  # Dockerfile's image instead of the lock's pin, and `build_args`,
  # `build_secrets`, `content_globs`, `structure_globs` and `prewarm` feed
  # that Dockerfile's build. They are read and honoured until the consumers
  # migrate; a lock with an `image` pin wins over them.
  #
  # volumes mount exactly as written. The container owns its own data root
  # (ADR-0008), so no volume is resolved against the host's locked trees;
  # what a container needs from the store, its own `dev up` installs.
  #
  # build_args maps docker --build-arg names to Dev::Credentials
  # "namespace/key" references, resolved only when the image is built.
  #
  # build_secrets maps BuildKit `--secret id=` names to the same "namespace/key"
  # references. Unlike build_args (which bake into image history), secrets are
  # mounted only for the RUN that requests them and never persist in a layer —
  # use them for a credential the image *build* itself must present. Only the
  # image builder needs them; pullers never do. When the credential exists to
  # fetch an artifact, prefer declaring the artifact as a dependency (e.g. the
  # wwise source) so it is fetched on the host and mounted in: the build then
  # needs no credential at all.
  #
  # run_env maps docker `run -e` env var names to the same "namespace/key"
  # references, resolved when a containerized command runs. Use it for
  # secrets a command needs at runtime (not baked into the image).
  #
  # content_globs adds project files (matched relative to the project root) to
  # the content-addressed image tag, on top of the always-hashed Dockerfile /
  # .dockerignore / lockfiles. Use it so structural inputs baked into the image
  # (e.g. a build script) invalidate the image when their *contents* change.
  #
  # structure_globs is the same idea but hashes only the *set of matching paths*,
  # not their contents: the existence of these files matters, not what is in
  # them. Use it when the file set is structural but per-file contents are not —
  # e.g. one *.Build.cs per build module, where adding/removing a module must
  # invalidate the image but editing a module's dependency list must not.
  #
  # prewarm, when set, switches image creation from a single `docker build` to a
  # build -> `docker run` -> `docker commit` flow: the Dockerfile builds the
  # cheap base, then this command runs inside a container with the build-dep
  # volumes mounted (robust `-v` virtiofs, unlike a streamed BuildKit
  # build-context) and build_secrets delivered as mounted files; the result is
  # committed to the content-addressed tag. Use it to bake an expensive warm
  # state that needs a large, randomly-read dependency (e.g. compiling against a
  # ~30GB engine) which a BuildKit build-context streams unreliably under
  # emulation.
  #
  # persist, when true, runs containerized commands inside a single long-lived
  # container (one `docker exec` per command) instead of a fresh `docker run
  # --rm` each time. The container's writable layer therefore survives between
  # commands, so an incremental build tool's state (object files, dependency
  # caches) written on top of the image is reused — a `--rm` container always
  # reverts to the image and recompiles everything that changed since it was
  # built. dev owns the container's lifecycle: it is created on demand, reused
  # while the image tag is unchanged, reaped when the tag changes, stopped
  # (kept warm) by `dev container down` and removed by `dev container reset`.
  # Default false (every other repo keeps `--rm`).
  # resources, when set, is the *floor* this project's build was tuned for:
  # `dev up` brings a colima VM up to at least it (ColimaProvisioner's
  # ratchet), and every containerized command measures the engine against
  # it first (EngineResourcesCheck — a hard failure, or a warning under the
  # `engine_resources: warn` setting). Absent means the provisioner's
  # defaults and no check.
  class BuildContainerConfig
    extend T::Sig

    # The optional VM sizing hint under build.container.resources. Every
    # field is optional: a repo can pin just the ones that matter.
    class Resources
      extend T::Sig

      # @return [Integer, nil] CPU count for the engine VM
      sig { returns(T.nilable(Integer)) }
      attr_reader :cpus

      # @return [Integer, nil] memory in GiB for the engine VM
      sig { returns(T.nilable(Integer)) }
      attr_reader :memory_gib

      # @return [Integer, nil] disk in GiB for the engine VM — what the
      #   container's data root and images need to fit on (ADR-0008);
      #   grow-only, applied by the colima provisioner, not checked
      sig { returns(T.nilable(Integer)) }
      attr_reader :disk_gib

      # @param cpus [Integer, nil] see #cpus
      # @param memory_gib [Integer, nil] see #memory_gib
      # @param disk_gib [Integer, nil] see #disk_gib
      sig { params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
      def initialize(cpus: nil, memory_gib: nil, disk_gib: nil)
        @cpus = cpus
        @memory_gib = memory_gib
        @disk_gib = disk_gib
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Resources) && @cpus == other.cpus && @memory_gib == other.memory_gib && @disk_gib == other.disk_gib
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [@cpus, @memory_gib, @disk_gib].hash
      end
    end

    # Deprecated (d3mlabs/dev#311): the hand-written-Dockerfile image's
    # name. nil when the project's image is its lock's `image` pin (dev#277).
    sig { returns(T.nilable(String)) }
    attr_reader :image

    # Deprecated (d3mlabs/dev#311): the hand-written-Dockerfile image's
    # registry. nil as above.
    sig { returns(T.nilable(String)) }
    attr_reader :registry

    sig { returns(T::Array[String]) }
    attr_reader :volumes

    sig { returns(T::Hash[String, String]) }
    attr_reader :build_args

    sig { returns(T::Hash[String, String]) }
    attr_reader :build_secrets

    sig { returns(T::Hash[String, String]) }
    attr_reader :run_env

    sig { returns(T::Array[String]) }
    attr_reader :content_globs

    sig { returns(T::Array[String]) }
    attr_reader :structure_globs

    sig { returns(T.nilable(String)) }
    attr_reader :prewarm

    sig { returns(T::Boolean) }
    attr_reader :persist

    sig { returns(T.nilable(Resources)) }
    attr_reader :resources

    sig do
      params(
        image: T.nilable(String),
        registry: T.nilable(String),
        volumes: T::Array[String],
        build_args: T::Hash[String, String],
        build_secrets: T::Hash[String, String],
        run_env: T::Hash[String, String],
        content_globs: T::Array[String],
        structure_globs: T::Array[String],
        prewarm: T.nilable(String),
        persist: T::Boolean,
        resources: T.nilable(Resources),
      ).void
    end
    def initialize(image: nil, registry: nil, volumes: [], build_args: {}, build_secrets: {},
                   run_env: {}, content_globs: [], structure_globs: [], prewarm: nil, persist: false,
                   resources: nil)
      @image = image
      @registry = registry
      @volumes = volumes
      @build_args = build_args
      @build_secrets = build_secrets
      @run_env = run_env
      @content_globs = content_globs
      @structure_globs = structure_globs
      @prewarm = prewarm
      @persist = persist
      @resources = resources
    end

    # Deprecated (d3mlabs/dev#311): the Dockerfile image's reference without
    # tag (e.g. "jpduchesne89/snappy-linux"); nil unless both halves are set.
    sig { returns(T.nilable(String)) }
    def image_ref
      return nil unless dockerfile_image?

      "#{@registry}/#{@image}"
    end

    # Whether the block names a hand-written-Dockerfile image (the deprecated
    # path) rather than leaving the image to the lock's pin.
    sig { returns(T::Boolean) }
    def dockerfile_image?
      !@image.nil? && !@registry.nil?
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(BuildContainerConfig)

      @image == other.image && @registry == other.registry &&
        @volumes == other.volumes && @build_args == other.build_args &&
        @build_secrets == other.build_secrets && @run_env == other.run_env &&
        @content_globs == other.content_globs && @structure_globs == other.structure_globs &&
        @prewarm == other.prewarm && @persist == other.persist && @resources == other.resources
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@image, @registry, @volumes, @build_args, @build_secrets, @run_env,
       @content_globs, @structure_globs, @prewarm, @persist, @resources].hash
    end
  end
end
