# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/build_container"
require "dev/deps/lockfile"
require "dev/engine_resources"
require "dev/environment_image"
require_relative "command"

module Dev
  # The project's environment images as its lock pins them (dev#277), and
  # the one answer every placement question goes through: which of them a
  # command runs in (`for`), by its `runs_on:` or by the project's shape
  # when it names none (dev#307). The lock is the only declaration: a
  # project pinning no image has no container and every command runs on
  # the host (the Dockerfile path that once filled that gap is gone,
  # dev#311 — its dev.yml keys are refused at load, ProjectManifestLoader).
  class ProjectImages
    extend T::Sig

    # Where a command runs: an image, or HOST (wherever dev itself runs).
    Placement = T.type_alias { T.any(EnvironmentImage, Symbol) }

    # `for`'s answer when the command runs on this host.
    HOST = :host

    # `runs_on:` names an image the lock does not pin.
    class UnknownImageError < ArgumentError; end

    # The lock holds several `image` pins and the command names none.
    class AmbiguousEnvironmentImageError < ArgumentError; end

    # @param root [Pathname] the checkout (its deps.lock is read, once)
    # @param engine [Dev::EngineResources::Hint, nil] the project's engine floor, measured before any image work
    sig { params(root: Pathname, engine: T.nilable(Dev::EngineResources::Hint)).void }
    def initialize(root:, engine: nil)
      @root = root
      @engine = engine
      @pins = T.let(nil, T.nilable(T::Array[Deps::Dependency]))
      @pinned = T.let(nil, T.nilable(T::Array[EnvironmentImage]))
    end

    # The lock's images, in lock order — every image the project's
    # lifecycle verbs act on.
    #
    # @return [Array<Dev::EnvironmentImage>]
    # @raise [EnvironmentImage::StaleDigestError] a pin was locked by another dev
    sig { returns(T::Array[EnvironmentImage]) }
    def pinned
      @pinned ||= pins.map { |pin| EnvironmentImage.from_pin(pin) }
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
    # lock pins an image. Membership only — nothing is materialised or
    # judged here, so a project whose images would be refused (`pinned`)
    # still gets the verbs that say why.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def containerized?
      pins.any?
    rescue Deps::Lockfile::RetiredBuildLockError
      # Membership never blocks the verb that fixes the lock (`dev deps
      # update`); the verbs that need the pins raise this themselves.
      false
    end

    # The command's environment.
    #
    # @param cmd [Dev::ProjectCommand]
    # @param name [String] the command's name, for messages
    # @return [Placement] an image, or HOST
    # @raise [UnknownImageError] `runs_on:` names an image the lock does not pin
    # @raise [AmbiguousEnvironmentImageError] no `runs_on:`, several pins
    sig { params(cmd: ProjectCommand, name: String).returns(Placement) }
    def for(cmd, name: cmd.run)
      return HOST if cmd.runs_on == ProjectCommand::HOST

      runs_on = cmd.runs_on
      if runs_on
        pinned.find { |image| image.name == runs_on } ||
          raise(UnknownImageError, "`#{name}` runs on `#{runs_on}`, which the lock does not pin; it pins: #{names_or_none}")
      elsif pinned.empty?
        HOST
      elsif pinned.size == 1
        T.must(pinned.first)
      else
        raise AmbiguousEnvironmentImageError,
          "`#{name}` runs in a container but names no image — this project declares #{pinned.size}: #{names_or_none}; " \
            "add `runs_on: <name>` to the command in dev.yml"
      end
    end

    # Make an image ready on the client's engine through
    # `ensure_environment_image!`, the project's engine floor measured first.
    #
    # @param image [Dev::EnvironmentImage]
    # @param client [Dev::BuildContainer]
    # @param publish [Boolean] the publisher designation (DEV_PUBLISH_IMAGE=1)
    # @return [String] the ready image's reference
    sig { params(image: EnvironmentImage, client: Dev::BuildContainer, publish: T::Boolean).returns(String) }
    def ensure!(image, client:, publish:)
      client.ensure_environment_image!(image, publish:, resources: @engine)
    end

    private

    # The lock's `image` pins, read once.
    #
    # @return [Array<Deps::Dependency>]
    sig { returns(T::Array[Deps::Dependency]) }
    def pins
      @pins ||= Deps::Lockfile.new(dir: @root).read.select { |pin| pin.integration == :image }
    end

    # @return [String] the pinned names, comma-separated, or "none"
    sig { returns(String) }
    def names_or_none
      pinned.empty? ? "none" : pinned.map(&:name).join(", ")
    end
  end
end
