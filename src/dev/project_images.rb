# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/build_container"
require "dev/build_container_config"
require "dev/deps/lockfile"
require "dev/engine_resources"
require "dev/environment_image"
require_relative "command"
require_relative "dockerfile_image"

module Dev
  # The project's environment images as its lock pins them (dev#277), and
  # the one answer every placement question goes through: which of them a
  # command runs in (`for`), by its `runs_on:` or by the project's shape
  # when it names none (dev#307). Also the one place the deprecated
  # Dockerfile path (d3mlabs/dev#311) is still chosen: a project with no
  # `image` pin and a `build.container.image/registry` block has that one
  # image, and its `container:` flags still mean what they did.
  #
  # The scoped refusal (dev#307 §0): the retired dev.yml keys are accepted
  # exactly while the lock pins no image. The moment it does, every one of
  # them is refused with its migration, in one message — a project migrates
  # in one PR and never writes a dev.yml it has to rewrite again.
  class ProjectImages
    extend T::Sig

    # A command's image, pinned or (until d3mlabs/dev#311) Dockerfile-built.
    Image = T.type_alias { T.any(EnvironmentImage, DockerfileImage) }

    # Where a command runs: an image, or HOST (wherever dev itself runs).
    Placement = T.type_alias { T.any(Image, Symbol) }

    # `for`'s answer when the command runs on this host.
    HOST = :host

    # `runs_on:` names an image the lock does not pin.
    class UnknownImageError < ArgumentError; end

    # The lock holds several `image` pins and the command names none.
    class AmbiguousEnvironmentImageError < ArgumentError; end

    # A container block with no image anywhere: no `image` pin in the lock
    # and no Dockerfile image named in the block.
    class NoEnvironmentImageError < ArgumentError; end

    # The lock pins an image and dev.yml still carries retired keys.
    class RetiredKeysError < ArgumentError; end

    # What each retired `build.container` key became.
    BLOCK_KEY_MIGRATIONS = T.let(
      {
        "image" => "delete it — the image is the lock's `image` pin",
        "registry" => "delete it — `registry:` on the `image` block, if not the floor's",
        "persist" => "`persist true` in the `image` block",
        "volumes" => "`volume \"…\"` lines in the `image` block",
        "run_env" => "`run_env \"VAR\" => \"ns/key\"` lines in the `image` block",
        "resources" => "`engine:` at the top level of dev.yml",
      }.freeze,
      T::Hash[String, String],
    )

    # @param root [Pathname] the checkout (its deps.lock is read, once)
    # @param build_container [Dev::BuildContainerConfig, nil] the retired block, when dev.yml has one
    # @param legacy_keys [Array<String>] the retired keys dev.yml carries (ProjectManifest#legacy_keys)
    # @param engine [Dev::EngineResources::Hint, nil] the project's engine floor, measured before any image work
    sig do
      params(
        root: Pathname,
        build_container: T.nilable(Dev::BuildContainerConfig),
        legacy_keys: T::Array[String],
        engine: T.nilable(Dev::EngineResources::Hint),
      ).void
    end
    def initialize(root:, build_container: nil, legacy_keys: [], engine: nil)
      @root = root
      @build_container = build_container
      @legacy_keys = legacy_keys
      @engine = engine
      @pins = T.let(nil, T.nilable(T::Array[Deps::Dependency]))
      @pinned = T.let(nil, T.nilable(T::Array[EnvironmentImage]))
    end

    # The lock's images, in lock order.
    #
    # @return [Array<Dev::EnvironmentImage>]
    # @raise [RetiredKeysError] when the lock pins an image and dev.yml carries retired keys
    # @raise [EnvironmentImage::StaleDigestError] a pin was locked by another dev
    sig { returns(T::Array[EnvironmentImage]) }
    def pinned
      @pinned ||= begin
        refuse_retired_keys! if pins.any? && @legacy_keys.any?
        pins.map { |pin| EnvironmentImage.from_pin(pin) }
      end
    end

    # Every image the project's lifecycle verbs act on: the lock's, or —
    # until d3mlabs/dev#311 — the one Dockerfile image the legacy block
    # names when the lock pins none.
    #
    # @return [Array<Image>]
    # @raise [RetiredKeysError, EnvironmentImage::StaleDigestError] as `pinned`
    # @raise [NoEnvironmentImageError] a block that names no image, with nothing pinned
    sig { returns(T::Array[Image]) }
    def all
      return pinned if pinned.any?

      [legacy].compact
    end

    # @param name [String] an `image` block's name
    # @return [Dev::EnvironmentImage]
    # @raise [UnknownImageError]
    sig { params(name: String).returns(EnvironmentImage) }
    def named(name)
      pinned.find { |image| image.name == name } ||
        raise(UnknownImageError, "no image named `#{name}`; the lock pins: #{names_or_none}")
    end

    # Whether any command of this project could run in a container: the
    # lock pins an image, or dev.yml carries the legacy block. Membership
    # only — nothing is materialised or judged here, so a project whose
    # images would be refused (`pinned`) still gets the verbs that say why.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def containerized?
      pins.any? || !@build_container.nil?
    rescue Deps::Lockfile::RetiredBuildLockError
      # Membership never blocks the verb that fixes the lock (`dev deps
      # update`); the verbs that need the pins raise this themselves.
      !@build_container.nil?
    end

    # The command's environment.
    #
    # @param cmd [Dev::ProjectCommand]
    # @param name [String] the command's name, for messages
    # @return [Placement] an image, or HOST
    # @raise [UnknownImageError] `runs_on:` names an image the lock does not pin
    # @raise [AmbiguousEnvironmentImageError] no `runs_on:`, several pins
    # @raise [NoEnvironmentImageError] a container block with no image anywhere
    sig { params(cmd: ProjectCommand, name: String).returns(Placement) }
    def for(cmd, name: cmd.run)
      return HOST if cmd.runs_on == ProjectCommand::HOST
      return legacy_placement(cmd, name) if pinned.empty?

      runs_on = cmd.runs_on
      if runs_on
        pinned.find { |image| image.name == runs_on } ||
          raise(UnknownImageError, "`#{name}` runs on `#{runs_on}`, which the lock does not pin; it pins: #{names_or_none}")
      elsif pinned.size == 1
        T.must(pinned.first)
      else
        raise AmbiguousEnvironmentImageError,
          "`#{name}` runs in a container but names no image — this project declares #{pinned.size}: #{names_or_none}; " \
            "add `runs_on: <name>` to the command in dev.yml"
      end
    end

    # Make an image ready on the client's engine: a pin through
    # `ensure_environment_image!`, the deprecated Dockerfile image through
    # its own path — the project's engine floor measured first either way.
    #
    # @param image [Image]
    # @param client [Dev::BuildContainer]
    # @param publish [Boolean] the publisher designation (DEV_PUBLISH_IMAGE=1)
    # @return [String] the ready image's reference
    sig { params(image: Image, client: Dev::BuildContainer, publish: T::Boolean).returns(String) }
    def ensure!(image, client:, publish:)
      case image
      when EnvironmentImage then client.ensure_environment_image!(image, publish:, resources: @engine)
      when DockerfileImage then image.ensure!(client:, publish:, resources: @engine)
      else T.absurd(image)
      end
    end

    private

    # The lock's `image` pins, read once.
    #
    # @return [Array<Deps::Dependency>]
    sig { returns(T::Array[Deps::Dependency]) }
    def pins
      @pins ||= Deps::Lockfile.new(dir: @root).read.select { |pin| pin.integration == :image }
    end

    # Deprecated (d3mlabs/dev#311): the block's Dockerfile image, when the
    # lock pins none.
    #
    # @return [Dev::DockerfileImage, nil] nil without a block naming one
    # @raise [NoEnvironmentImageError] a block that names no image, with nothing pinned
    sig { returns(T.nilable(DockerfileImage)) }
    def legacy
      config = @build_container
      return nil if config.nil? || pinned.any?
      unless config.dockerfile_image?
        raise NoEnvironmentImageError,
          "#{@root} declares no image: add an `image` block to dependencies.rb and run: dev deps update"
      end

      DockerfileImage.new(root: @root, config:)
    end

    # Deprecated (d3mlabs/dev#311): the legacy path's answer — `container:
    # false` is the host, anything else the one Dockerfile image; a
    # `runs_on:` naming an image has nothing to name.
    #
    # @param cmd [Dev::ProjectCommand]
    # @param name [String]
    # @return [Placement]
    # @raise [UnknownImageError, NoEnvironmentImageError]
    sig { params(cmd: ProjectCommand, name: String).returns(Placement) }
    def legacy_placement(cmd, name)
      if cmd.runs_on
        raise UnknownImageError,
          "`#{name}` runs on `#{cmd.runs_on}`, but the lock pins none: add an `image` block to dependencies.rb " \
            "and run: dev deps update"
      end

      image = legacy
      return HOST if image.nil? || !cmd.container

      image
    end

    # @return [String] the pinned names, comma-separated, or "none"
    sig { returns(String) }
    def names_or_none
      pinned.empty? ? "none" : pinned.map(&:name).join(", ")
    end

    # @return [void]
    # @raise [RetiredKeysError]
    sig { void }
    def refuse_retired_keys!
      lines = @legacy_keys.flat_map { |key| migrations_for(key) }
      raise RetiredKeysError,
        "the lock pins an image, so dev.yml's retired keys are refused (d3mlabs/dev#307):\n  " \
          "#{lines.join("\n  ")}"
    end

    # @param key [String] a ProjectManifest#legacy_keys entry
    # @return [Array<String>] one line per retired key with where it goes
    sig { params(key: String).returns(T::Array[String]) }
    def migrations_for(key)
      case key
      when "build.container" then block_migrations
      when "build.container.resources" then ["#{key} → #{BLOCK_KEY_MIGRATIONS.fetch("resources")}"]
      when /\.container: false\z/ then ["#{key} → `runs_on: #{ProjectCommand::HOST}`"]
      else ["#{key} → delete it (the image's name under `runs_on:`, or nothing)"]
      end
    end

    # @return [Array<String>] a line per key the retired block actually carries
    sig { returns(T::Array[String]) }
    def block_migrations
      config = T.must(@build_container)
      present = {
        "image" => config.image, "registry" => config.registry, "persist" => config.persist,
        "volumes" => config.volumes.any?, "run_env" => config.run_env.any?,
      }.select { |_, value| value }.keys
      lines = present.map { |field| "build.container.#{field} → #{BLOCK_KEY_MIGRATIONS.fetch(field)}" }
      lines.empty? ? ["build.container → delete the block"] : lines
    end
  end
end
