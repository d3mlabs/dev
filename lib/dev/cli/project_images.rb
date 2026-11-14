# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/environment_ref"
require_relative "placement"

module Dev
  module Cli
    # The project's environment images as its lock pins them, and
    # the one answer every placement question goes through: which of them an
    # `environment:` reference binds to (`bind`), by name or by the project's
    # shape when it names none. The lock is the only declaration: a
    # project pinning no image has no container and every command runs on
    # the host.
    #
    # Binding is reference → placement, with no command in the
    # signature: the composition root binds every command's reference at
    # load (PlacementBinder), and a lifecycle target's `environment:` binds
    # through the same call.
    class ProjectImages
      extend T::Sig

      # `environment:` names an image the lock does not pin.
      class UnknownImageError < ArgumentError; end

      # The lock holds several `image` pins and the reference names none.
      class AmbiguousEnvironmentImageError < ArgumentError; end

      # @param root [Pathname] the checkout (its deps.lock is read, once)
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
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

      # Bind an `environment:` reference against the lock. Host binds without
      # reading the lock; an image name must be a pin's; no reference means
      # the project's one image when exactly one is pinned, the host when
      # none is — and a refusal, both names listed, when several are: dev
      # never guesses.
      #
      # @param ref [Dev::EnvironmentRef, nil] the reference as declared; nil
      #   when the declaration left the choice to the project
      # @param subject [String] what the messages call the thing being
      #   placed — a command's path (`test editor`), later a target's name
      # @return [Dev::Cli::Placement]
      # @raise [UnknownImageError] the reference names an image the lock does not pin
      # @raise [AmbiguousEnvironmentImageError] no reference, several pins
      sig { params(ref: T.nilable(EnvironmentRef), subject: String).returns(Placement) }
      def bind(ref, subject:)
        case ref
        when nil
          bind_default(subject)
        when EnvironmentRef::Host
          Placement::Host.new
        when EnvironmentRef::Image
          image = pinned.find { |pin| pin.name == ref.name } ||
            raise(UnknownImageError, "`#{subject}` runs in `#{ref.name}`, which the lock does not pin; it pins: #{names_or_none}")
          Placement::Image.new(image:)
        else
          # simplecov:disable — the sealed reference has no third shape;
          # T.absurd keeps the static proof.
          T.absurd(ref)
          # simplecov:enable
        end
      end

      private

      # The project's default environment: its one image, the host when it
      # pins none, a refusal naming the key to add when it pins several.
      #
      # @param subject [String] see #bind
      # @return [Dev::Cli::Placement]
      # @raise [AmbiguousEnvironmentImageError]
      sig { params(subject: String).returns(Placement) }
      def bind_default(subject)
        return Placement::Host.new if pinned.empty?
        return Placement::Image.new(image: T.must(pinned.first)) if pinned.size == 1

        raise AmbiguousEnvironmentImageError,
          "`#{subject}` runs in a container but names no image — this project declares #{pinned.size}: #{names_or_none}; " \
            "add `environment: <name>` to the command in dev.yml"
      end

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
end
