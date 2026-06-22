# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for the build.container block in dev.yml.
  #
  # When present, commands run inside a Docker container by default.
  # Content-addressed image tags are computed from Dockerfile + build-deps.lock.
  #
  # dev.yml example:
  #   build:
  #     container:
  #       image: snappy-linux
  #       registry: jpduchesne89
  #       volumes:
  #         - "~/.dev/engines/unreal-engine-css:/ue"
  #       build_args:
  #         WWISE_EMAIL: wwise/email
  #         WWISE_PASSWORD: wwise/password
  #       build_secrets:
  #         WWISE_TOKEN: wwise/token
  #       run_env:
  #         WWISE_TOKEN: wwise/token
  #       content_globs:
  #         - "Mods/*/Source/*/*.Build.cs"
  #
  # build_args maps docker --build-arg names to Dev::Credentials
  # "namespace/key" references, resolved only when the image is built.
  #
  # build_secrets maps BuildKit `--secret id=` names to the same "namespace/key"
  # references. Unlike build_args (which bake into image history), secrets are
  # mounted only for the RUN that requests them and never persist in a layer —
  # use them for tokens the image *build* needs (e.g. fetching a gated SDK).
  # Only the image builder needs them; pullers never do.
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
  # while the image tag is unchanged, reaped when the tag changes, and removed
  # by `dev reset-container`. Default false (every other repo keeps `--rm`).
  class BuildContainerConfig
    extend T::Sig

    sig { returns(String) }
    attr_reader :image

    sig { returns(String) }
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

    sig do
      params(
        image: String,
        registry: String,
        volumes: T::Array[String],
        build_args: T::Hash[String, String],
        build_secrets: T::Hash[String, String],
        run_env: T::Hash[String, String],
        content_globs: T::Array[String],
        structure_globs: T::Array[String],
        prewarm: T.nilable(String),
        persist: T::Boolean,
      ).void
    end
    def initialize(image:, registry:, volumes: [], build_args: {}, build_secrets: {},
                   run_env: {}, content_globs: [], structure_globs: [], prewarm: nil, persist: false)
      @image = T.let(image, String)
      @registry = T.let(registry, String)
      @volumes = T.let(volumes, T::Array[String])
      @build_args = T.let(build_args, T::Hash[String, String])
      @build_secrets = T.let(build_secrets, T::Hash[String, String])
      @run_env = T.let(run_env, T::Hash[String, String])
      @content_globs = T.let(content_globs, T::Array[String])
      @structure_globs = T.let(structure_globs, T::Array[String])
      @prewarm = T.let(prewarm, T.nilable(String))
      @persist = T.let(persist, T::Boolean)
    end

    # Full image reference without tag (e.g. "jpduchesne89/snappy-linux").
    sig { returns(String) }
    def image_ref
      "#{@registry}/#{@image}"
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(BuildContainerConfig)

      @image == other.image && @registry == other.registry &&
        @volumes == other.volumes && @build_args == other.build_args &&
        @build_secrets == other.build_secrets && @run_env == other.run_env &&
        @content_globs == other.content_globs && @structure_globs == other.structure_globs &&
        @prewarm == other.prewarm && @persist == other.persist
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@image, @registry, @volumes, @build_args, @build_secrets, @run_env,
       @content_globs, @structure_globs, @prewarm, @persist].hash
    end
  end
end
