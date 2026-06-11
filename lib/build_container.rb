# frozen_string_literal: true

require "digest"
require "pathname"

# Content-addressed Docker image management for build containers.
#
# Computes a tag from the hash of Dockerfile + .dockerignore + build-deps.lock.
# Any change to those files produces a new tag, guaranteeing a rebuild.
#
# Usage:
#   BuildContainer.ensure_image!(config, project_root: Pathname("..."))
#     # pulls or builds the image, returns the full image:tag string
#
#   BuildContainer.content_tag(project_root: Pathname("..."))
#     # returns the content-addressed tag without side effects
module BuildContainer
  CONTENT_FILES = ["Dockerfile", ".dockerignore", "build-deps.lock"].freeze
  TAG_PREFIX = "content-"

  module_function

  # Compute the content-addressed tag from Dockerfile + lockfiles.
  #
  # @param project_root [Pathname] project root containing Dockerfile etc.
  # @return [String] tag like "content-a1b2c3d4e5f6"
  def content_tag(project_root:)
    root = Pathname(project_root)
    content = CONTENT_FILES
      .map { |f| root / f }
      .select(&:exist?)
      .map(&:read)
      .join

    hash = Digest::SHA256.hexdigest(content)[0, 12]
    "#{TAG_PREFIX}#{hash}"
  end

  # Full image reference with content-addressed tag.
  #
  # @param config       [Dev::BuildContainerConfig]
  # @param project_root [Pathname]
  # @return [String] e.g. "jpduchesne89/snappy-linux:content-a1b2c3d4e5f6"
  def image_with_tag(config, project_root:)
    "#{config.image_ref}:#{content_tag(project_root:)}"
  end

  # Ensure the build container image exists: use a local image if present,
  # pull from registry if available, otherwise build and push. Returns the
  # full image:tag string.
  #
  # The local check comes first so images built manually are honored.
  #
  # build_args_provider is a lazy source of docker --build-arg values
  # (e.g. credentials). It is only called on a cache miss so cache hits
  # never trigger credential resolution or prompts.
  #
  # @param config              [Dev::BuildContainerConfig]
  # @param project_root        [Pathname]
  # @param push                [Boolean] whether to push after building (default: true)
  # @param build_args_provider [#call, nil] returns Hash{String => String} of build args
  # @return [String] the full image:tag string
  def ensure_image!(config, project_root:, push: true, build_args_provider: nil)
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
    build!(tag, project_root:, build_args: build_args)
    push!(tag) if push
    tag
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
    volume_flags = volumes.flat_map do |spec|
      host, container = spec.split(":", 2)
      ["-v", "#{File.expand_path(host)}:#{container}"]
    end

    env_flags = env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }

    [
      "docker", "run", "--rm",
      "-v", "#{project_root}:/project",
      *volume_flags,
      *env_flags,
      "-w", "/project",
      image_tag,
      "sh", "-c", shell_cmd,
    ]
  end

  # --- internal helpers ------------------------------------------------

  def local_image?(image_tag)
    system("docker", "image", "inspect", image_tag, out: File::NULL, err: File::NULL)
  end

  def pull(image_tag)
    system("docker", "pull", image_tag, out: File::NULL, err: File::NULL)
  end

  def build!(image_tag, project_root:, build_args: {})
    arg_flags = build_args.flat_map { |name, value| ["--build-arg", "#{name}=#{value}"] }
    success = system("docker", "build", "-t", image_tag, *arg_flags, project_root.to_s)
    raise "Docker build failed for #{image_tag}" unless success
  end

  def push!(image_tag)
    system("docker", "push", image_tag, out: File::NULL, err: File::NULL)
  end
end
