# frozen_string_literal: true

require "digest"
require "pathname"
require "yaml"

# Content-addressed Docker image management for build containers.
#
# Computes a tag from the hash of Dockerfile + .dockerignore + lockfiles
# (deps.lock, build-deps.lock) plus any project-declared content globs. Any
# change to those inputs produces a new tag, guaranteeing a rebuild.
#
# Usage:
#   BuildContainer.ensure_image!(config, project_root: Pathname("..."))
#     # pulls or builds the image, returns the full image:tag string
#
#   BuildContainer.content_tag(project_root: Pathname("..."))
#     # returns the content-addressed tag without side effects
module BuildContainer
  # Always-hashed inputs. deps.lock (app/test deps, e.g. SML) and build-deps.lock
  # (build deps, e.g. the engine) join the Dockerfile so a dependency bump
  # invalidates a prewarmed image. Missing files are skipped (see content_tag).
  CONTENT_FILES = ["Dockerfile", ".dockerignore", "deps.lock", "build-deps.lock"].freeze
  TAG_PREFIX = "content-"
  BUILD_DEPS_LOCK = "build-deps.lock"
  # Both lockfiles are scanned for version-keyed install_dir resolution: gh
  # build deps (e.g. the engine) land in build-deps.lock, while integration
  # deps (e.g. the Satisfactory server) land in deps.lock.
  LOCKFILES = ["deps.lock", "build-deps.lock"].freeze

  module_function

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
  def image_with_tag(config, project_root:)
    globs = config.respond_to?(:content_globs) ? config.content_globs : []
    structure_globs = config.respond_to?(:structure_globs) ? config.structure_globs : []
    "#{config.image_ref}:#{content_tag(project_root:, extra_globs: globs, structure_globs:)}"
  end

  # Ensure the build container image exists: use a local image if present,
  # pull from registry if available, otherwise build and push. Returns the
  # full image:tag string.
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
  # @param config              [Dev::BuildContainerConfig]
  # @param project_root        [Pathname]
  # @param push                [Boolean] whether to push after building (default: true)
  # @param build_args_provider [#call, nil] returns Hash{String => String} of build args
  # @param secrets_provider    [#call, nil] returns Hash{String => String} of secret id => value
  # @return [String] the full image:tag string
  def ensure_image!(config, project_root:, push: true, build_args_provider: nil,
                    secrets_provider: nil)
    tag = image_with_tag(config, project_root:)

    if local_image?(tag)
      $stderr.puts "dev: Container image found locally — #{tag}"
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
      build_contexts = build_contexts_from_lockfile(project_root)
      build!(tag, project_root:, build_args:, build_contexts:, secrets:)
    end

    push!(tag) if push
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
  # plain `-v` volume (virtiofs on Docker Desktop) is the robust path the runtime
  # already uses, so the prewarm reuses it.
  #
  # @param tag          [String] final content-addressed tag to commit
  # @param config       [Dev::BuildContainerConfig]
  # @param project_root [Pathname]
  # @param build_args   [Hash{String => String}]
  # @param secrets      [Hash{String => String}] secret id => value
  # @param prewarm      [String] shell command to run inside the base container
  def build_and_prewarm!(tag, config:, project_root:, build_args:, secrets:, prewarm:)
    base_tag = "#{tag}-base"
    # The base is engine-free and secret-free: no build-contexts, no BuildKit
    # secrets. Those are supplied to the prewarm run, not the Dockerfile.
    build!(base_tag, project_root:, build_args:, build_contexts: {}, secrets: {})
    volumes = resolve_versioned_volumes(config.volumes, project_root:)
    prewarm_commit!(base_tag, tag, volumes:, prewarm:, secrets:)
  ensure
    # The committed image references the base's layers, so dropping the base tag
    # frees the name without removing shared data.
    remove_image(base_tag)
  end

  # Named build-contexts derived from build-deps.lock: every build-group
  # dependency with an install_dir becomes "<dep-name>=<expanded host path>".
  # The context name is lowercased because Docker rejects uppercase build-context
  # names ("invalid reference format"); the Dockerfile references the lowercased
  # name (e.g. `--mount=from=unrealengine`). Returns {} when the lockfile is
  # absent or has no such deps.
  #
  # @param project_root [Pathname]
  # @return [Hash{String => String}] context name => absolute host path
  def build_contexts_from_lockfile(project_root)
    path = Pathname(project_root) / BUILD_DEPS_LOCK
    return {} unless path.exist?

    require "yaml"
    yaml = YAML.safe_load(path.read, permitted_classes: [Symbol]) || {}

    contexts = {}
    yaml.each do |name, attrs|
      next if name == "env" # env-scoped deps are not whole-image build inputs
      next unless attrs.is_a?(Hash)
      next unless attrs["group"] == "build" && attrs["install_dir"]

      base = File.expand_path(attrs["install_dir"])
      # Point at the version-keyed subdir the integration publishes to, so the
      # build context tracks the locked version (see resolve_versioned_volumes).
      contexts[name.downcase] = attrs["version"] ? File.join(base, attrs["version"].to_s) : base
    end
    contexts
  end

  # Rewrite each "host:container[:opts]" volume whose host path is a locked
  # dependency's install_dir to its version-keyed subdir (install_dir/<version>,
  # the immutable directory the integration publishes). This is how a command
  # mounts the exact locked version while the integration keeps every version
  # side by side. Volumes that don't match a locked install_dir (e.g. the shared
  # cache mount) pass through unchanged.
  #
  # @param volumes      [Array<String>] configured "host:container[:opts]" specs
  # @param project_root [Pathname]
  # @return [Array<String>] specs with matching host paths version-resolved
  def resolve_versioned_volumes(volumes, project_root:)
    versions = install_dir_versions(project_root)
    return volumes if versions.empty?

    volumes.map do |spec|
      host, container = spec.split(":", 2)
      version = versions[File.expand_path(host)]
      version ? "#{host}/#{version}:#{container}" : spec
    end
  end

  # Map every locked dependency install_dir (expanded) to its locked version,
  # scanning both lockfiles (including env-nested build deps). Only entries with
  # BOTH an install_dir and a version contribute.
  #
  # @param project_root [Pathname]
  # @return [Hash{String => String}] expanded install_dir => version
  def install_dir_versions(project_root)
    root = Pathname(project_root)
    LOCKFILES.each_with_object({}) do |file, acc|
      path = root / file
      next unless path.exist?

      yaml = YAML.safe_load(path.read, permitted_classes: [Symbol]) || {}
      collect_install_dir_versions(yaml, acc)
    end
  end

  # Recursively collect {expanded install_dir => version} from a lockfile hash,
  # descending into the nested env: section of build-deps.lock.
  #
  # @param yaml [Hash]
  # @param acc  [Hash{String => String}] accumulator (mutated)
  # @return [void]
  def collect_install_dir_versions(yaml, acc)
    yaml.each do |name, attrs|
      next unless attrs.is_a?(Hash)

      if name == "env"
        attrs.each_value { |env_deps| collect_install_dir_versions(env_deps, acc) }
      elsif attrs["install_dir"] && attrs["version"]
        acc[File.expand_path(attrs["install_dir"])] = attrs["version"].to_s
      end
    end
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
  def docker_run_command(image_tag, project_root:, shell_cmd:, volumes: [], env: {})
    env_flags = env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }

    [
      "docker", "run", "--rm",
      "-v", "#{project_root}:/project",
      *volume_flags(volumes),
      *env_flags,
      "-w", "/project",
      image_tag,
      "sh", "-c", shell_cmd,
    ]
  end

  # "host:container" volume specs -> docker `-v` flags, expanding ~ in the host
  # path (e.g. "~/.dev/engines/...:/ue").
  #
  # @param volumes [Array<String>]
  # @return [Array<String>]
  def volume_flags(volumes)
    volumes.flat_map do |spec|
      host, container = spec.split(":", 2)
      ["-v", "#{File.expand_path(host)}:#{container}"]
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
  def ensure_service!(image_tag, project_root:, volumes: [])
    name = service_container_name(image_tag)
    reap_stale_services!(image_tag)

    if container_exists?(name)
      start_container(name) unless container_running?(name)
    else
      create_service_container(name, image_tag, project_root:, volumes:)
    end
    name
  end

  # Build a `docker exec` command running shell_cmd inside the service container,
  # mirroring docker_run_command's working dir (/project) and `-e` env handling.
  #
  # @param container [String] running container name
  # @param shell_cmd [String]
  # @param env       [Hash{String => String}] env vars to inject via `-e`
  # @return [Array<String>] docker exec command array
  def docker_exec_command(container, shell_cmd:, env: {})
    env_flags = env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }
    ["docker", "exec", *env_flags, "-w", "/project", container, "sh", "-c", shell_cmd]
  end

  # Remove every service container for this project — the current tag's and any
  # stale one — backing `dev reset-container`. Keyed by the project/image prefix
  # (not the exact tag) so a container from a now-superseded Dockerfile/dep is
  # still matched.
  #
  # @param image_tag [String]
  # @return [Array<String>] names of the removed containers
  def reset_service!(image_tag)
    names = service_containers(service_name_prefix(image_tag))
    names.each { |name| remove_container(name) }
    names
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
  def prewarm_commit!(base_tag, final_tag, volumes:, prewarm:, secrets:)
    container = prewarm_container_name
    secret_files = write_secret_files(secrets)
    secret_mounts = secret_files.flat_map { |id, path| ["-v", "#{path}:/run/secrets/#{id}:ro"] }

    run_argv = [
      "docker", "run", "--name", container,
      *volume_flags(volumes),
      *secret_mounts,
      base_tag,
      "sh", "-c", prewarm,
    ]

    raise "Prewarm run failed for #{final_tag}" unless run_watched(run_argv, container: container)
    raise "docker commit failed for #{final_tag}" unless system("docker", "commit", container, final_tag)
  ensure
    system("docker", "rm", "-f", container, out: File::NULL, err: File::NULL)
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
  def run_watched(argv, container:)
    require "build_watcher"
    BuildWatcher.new(container_name: container).run(argv)
  end

  # Write each secret value to a private host temp file for bind-mounting into
  # the prewarm container. Returns {id => path}; caller deletes the files.
  #
  # @param secrets [Hash{String => String}]
  # @return [Hash{String => String}] secret id => temp file path
  def write_secret_files(secrets)
    require "tmpdir"
    require "securerandom"
    secrets.each_with_object({}) do |(id, value), files|
      path = File.join(Dir.tmpdir, "dev-secret-#{SecureRandom.hex(8)}")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(value) }
      files[id] = path
    end
  end

  # --- internal helpers ------------------------------------------------

  # Unique name for the throwaway prewarm container; pid + random suffix so
  # concurrent dev invocations never collide.
  def prewarm_container_name
    "dev-prewarm-#{Process.pid}-#{rand(1_000_000)}"
  end

  def remove_image(image_tag)
    system("docker", "image", "rm", "-f", image_tag, out: File::NULL, err: File::NULL)
  end

  # Container name for image_tag: "dev-<image>-<tag>", registry dropped and any
  # char Docker forbids in a name (notably ':') replaced with '-'. E.g.
  # "reg/snappy-linux:content-abc" -> "dev-snappy-linux-content-abc".
  def service_container_name(image_tag)
    "dev-#{sanitize_container_name(image_tag.split("/").last)}"
  end

  # Project/image prefix shared by every tag's container, used to find and reap
  # stale ones. E.g. "reg/snappy-linux:content-abc" -> "dev-snappy-linux-".
  def service_name_prefix(image_tag)
    image = image_tag.split("/").last.split(":").first
    "dev-#{sanitize_container_name(image)}-"
  end

  def sanitize_container_name(str)
    str.gsub(/[^a-zA-Z0-9_.-]/, "-")
  end

  # Remove service containers for this project that don't match the current
  # tag's name, so a Dockerfile/dep bump (new tag) doesn't leave the old one
  # running alongside the new.
  def reap_stale_services!(image_tag)
    keep = service_container_name(image_tag)
    service_containers(service_name_prefix(image_tag)).each do |name|
      remove_container(name) unless name == keep
    end
  end

  # Names of existing containers (running or stopped) whose name matches the
  # project prefix. `^` anchors the regex name filter to the start.
  def service_containers(prefix)
    out = `docker ps -a --filter name=^#{prefix} --format {{.Names}}`
    out.split("\n").map(&:strip).reject(&:empty?)
  end

  def container_exists?(name)
    system("docker", "container", "inspect", name, out: File::NULL, err: File::NULL)
  end

  def container_running?(name)
    `docker container inspect -f {{.State.Running}} #{name} 2>/dev/null`.strip == "true"
  end

  def start_container(name)
    system("docker", "start", name, out: File::NULL, err: File::NULL)
  end

  # Create the detached, idle service container: the project at /project, any
  # extra volumes (e.g. the engine), and `sleep infinity` so it stays up for
  # `docker exec`.
  def create_service_container(name, image_tag, project_root:, volumes: [])
    success = system(
      "docker", "run", "-d", "--name", name,
      "-v", "#{project_root}:/project",
      *volume_flags(volumes),
      "-w", "/project",
      image_tag,
      "sleep", "infinity",
      out: File::NULL, err: File::NULL,
    )
    raise "Failed to create service container #{name}" unless success
  end

  def remove_container(name)
    system("docker", "rm", "-f", name, out: File::NULL, err: File::NULL)
  end

  def local_image?(image_tag)
    system("docker", "image", "inspect", image_tag, out: File::NULL, err: File::NULL)
  end

  def pull(image_tag)
    system("docker", "pull", image_tag, out: File::NULL, err: File::NULL)
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
  def build!(image_tag, project_root:, build_args: {}, build_contexts: {}, secrets: {})
    arg_flags = build_args.flat_map { |name, value| ["--build-arg", "#{name}=#{value}"] }
    context_flags = build_contexts.flat_map { |name, path| ["--build-context", "#{name}=#{path}"] }
    secret_flags = secrets.keys.flat_map { |id| ["--secret", "id=#{id},env=#{id}"] }

    # BuildKit is required for --build-context and --secret; enable it explicitly
    # so the build behaves the same regardless of the host Docker default. Secret
    # values travel via the environment (referenced by env=), never on argv.
    env = { "DOCKER_BUILDKIT" => "1" }.merge(secrets)

    success = system(
      env,
      "docker", "build", "-t", image_tag,
      *arg_flags, *context_flags, *secret_flags,
      project_root.to_s,
    )
    raise "Docker build failed for #{image_tag}" unless success
  end

  def push!(image_tag)
    system("docker", "push", image_tag, out: File::NULL, err: File::NULL)
  end
end
