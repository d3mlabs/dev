# typed: strict
# frozen_string_literal: true

require "digest"
require "shellwords"

require "dev/deps/dependency"
require "dev/platform"

module Dev
  # A project's environment image as the lock describes it (dev#277): the
  # floor pinned by digest, the platform, the apt set — and what dev makes
  # of them: the Dockerfile it builds, and the content digest that is the
  # image's identity.
  #
  # Pure. The digest is the SHA-256 of the generated Dockerfile text, so it
  # covers the floor's digest, the platform, the sorted apt set and dev's
  # own template — a change to what dev bakes in re-mints every image, as
  # it should. The text carries no digest itself (the marker's value arrives
  # as a build arg), so the identity has one definition. The same 64 hex are
  # the registry tag, the lock's `digest`, the marker's `digest=` inside the
  # image: every compare, dev#308's host rule included, is equality.
  #
  # The lock stores the digest (UpdateDepsCommand stamps it via with_digest)
  # and from_pin checks it: a dev whose template differs from the one that
  # locked refuses with the re-lock to run, so the re-mint is a reviewed
  # lock diff and never a silent rebuild.
  class EnvironmentImage
    extend T::Sig

    # The pin's `platform` is absent with a multi-arch floor, or names one
    # the floor does not publish.
    class PlatformError < StandardError; end

    # The lock's `digest` is not what this dev computes for the entry: the
    # entry was locked by a dev with another template.
    class StaleDigestError < StandardError; end

    # The floor contract dev's template relies on (ADR-0006, build-base): the
    # unprivileged user builds run as, and Linuxbrew's fixed prefix, a
    # named volume at run time.
    FLOOR_USER = "builder"
    LINUXBREW_PREFIX = "/home/linuxbrew/.linuxbrew"

    # Where the checkout is bind-mounted in every container dev creates.
    PROJECT_MOUNT = "/project"

    # The file a host or container carries to say which environment it is
    # (dev#308 compares it to the lock): `name=…\ndigest=…\n`.
    MARKER_PATH = "/etc/dev/environment"

    # The build arg the marker's digest arrives through.
    DIGEST_BUILD_ARG = "DEV_ENVIRONMENT_DIGEST"

    # The lock metadata key the stored digest lives under.
    DIGEST_KEY = "digest"

    # How many hex of the digest a container name or a log line shows.
    SHORT_DIGEST_LENGTH = 12

    sig { returns(String) }
    attr_reader :name

    # @return [String] the floor, `<registry>/<repository>`
    sig { returns(String) }
    attr_reader :from

    # @return [String] the floor's manifest digest, 64 hex
    sig { returns(String) }
    attr_reader :from_digest

    # @return [String] docker platform, `os/arch[/variant]`
    sig { returns(String) }
    attr_reader :platform

    # @return [Array<String>] sorted, unique Debian package names
    sig { returns(T::Array[String]) }
    attr_reader :apt

    # @return [String] the registry prefix the image publishes under
    sig { returns(String) }
    attr_reader :registry

    class << self
      extend T::Sig

      # Read an image off its lock pin.
      #
      # @param pin [Dev::Deps::Dependency] an `:image` pin
      # @return [EnvironmentImage]
      # @raise [PlatformError, StaleDigestError]
      sig { params(pin: Dev::Deps::Dependency).returns(EnvironmentImage) }
      def from_pin(pin)
        metadata = pin.metadata
        image = new(
          name: pin.name,
          from: metadata.fetch("from"),
          from_digest: pin.hash.to_s.delete_prefix("SHA256="),
          platform: resolve_platform(pin.name, metadata["platform"], Array(metadata["platforms"])),
          apt: Array(metadata["apt"]).map(&:to_s),
          registry: metadata.fetch("registry"),
        )
        stored = metadata[DIGEST_KEY]
        if stored && stored != image.digest
          raise StaleDigestError,
            "image #{pin.name} was locked by another dev (digest #{stored[0, SHORT_DIGEST_LENGTH]}, " \
              "this dev computes #{image.short_digest}) — run: dev deps update"
        end
        image
      end

      # A docker platform (`linux/arm64/v8`) as dev's key (`linux-arm64`):
      # the variant is docker's, dev's keys have none.
      #
      # @param docker_platform [String]
      # @return [String]
      sig { params(docker_platform: String).returns(String) }
      def dev_platform_of(docker_platform)
        Platform.from_docker(docker_platform.split("/").take(2).join("/"))
      end

      # The lock-side step of a re-lock: every `:image` pin stamped with the
      # digest this dev computes for it (a stale stored one is replaced —
      # the re-lock is where staleness is cured), other pins untouched.
      #
      # @param pins [Array<Dev::Deps::Dependency>] the resolved pins
      # @return [Array<Dev::Deps::Dependency>]
      # @raise [PlatformError]
      sig { params(pins: T::Array[Dev::Deps::Dependency]).returns(T::Array[Dev::Deps::Dependency]) }
      def stamp(pins)
        pins.map do |pin|
          next pin unless pin.integration == :image

          recipe = pin.with(metadata: pin.metadata.except(DIGEST_KEY))
          from_pin(recipe).with_digest(recipe)
        end
      end

      private

      # @param name [String]
      # @param declared [String, nil] the block's `platform`
      # @param published [Array<String>] the floor's platforms
      # @return [String]
      # @raise [PlatformError]
      sig { params(name: String, declared: T.nilable(String), published: T::Array[String]).returns(String) }
      def resolve_platform(name, declared, published)
        if declared.nil?
          return T.must(published.first) if published.size == 1

          raise PlatformError,
            "image #{name}: the floor publishes #{published.size} platforms (#{published.join(", ")}) — " \
              "name one with `platform \"…\"` in the image block"
        end
        unless published.empty? || published.include?(declared)
          raise PlatformError,
            "image #{name}: platform #{declared} is not one the floor publishes (#{published.join(", ")})"
        end

        declared
      end
    end

    sig do
      params(name: String, from: String, from_digest: String, platform: String, apt: T::Array[String], registry: String).void
    end
    def initialize(name:, from:, from_digest:, platform:, apt:, registry:)
      @name = name
      @from = from
      @from_digest = from_digest
      @platform = platform
      @apt = T.let(apt.sort.uniq.freeze, T::Array[String])
      @registry = registry
    end

    # @return [String] the floor pinned by digest — what the FROM line pulls
    sig { returns(String) }
    def floor_ref = "#{@from}@sha256:#{@from_digest}"

    # The Dockerfile dev builds. Root only for the apt layer and the marker;
    # the floor's final user is restored. The apt lists are removed so the
    # layer carries packages, not indexes.
    #
    # @return [String]
    sig { returns(String) }
    def dockerfile
      lines = [
        "FROM --platform=#{@platform} #{floor_ref}",
        "USER root",
        "ENV DEBIAN_FRONTEND=noninteractive",
      ]
      unless @apt.empty?
        lines << "RUN apt-get -y update \\"
        lines << "    && apt-get -y install --no-install-recommends #{@apt.join(" ")} \\"
        lines << "    && apt-get clean \\"
        lines << "    && rm -rf /var/lib/apt/lists/*"
      end
      lines << "ENV PATH=\"#{LINUXBREW_PREFIX}/bin:#{LINUXBREW_PREFIX}/sbin:$PATH\""
      lines << "ARG #{DIGEST_BUILD_ARG}"
      lines << "RUN install -d #{File.dirname(MARKER_PATH)} \\"
      lines << "    && printf 'name=%s\\ndigest=%s\\n' #{Shellwords.escape(@name)} \"$#{DIGEST_BUILD_ARG}\" > #{MARKER_PATH}"
      lines << "USER #{FLOOR_USER}"
      lines << "WORKDIR #{PROJECT_MOUNT}"
      "#{lines.join("\n")}\n"
    end

    # @return [String] the image's identity: SHA-256 of the Dockerfile, 64 hex
    sig { returns(String) }
    def digest
      @digest ||= T.let(Digest::SHA256.hexdigest(dockerfile), T.nilable(String))
    end

    # @return [String] the first SHORT_DIGEST_LENGTH hex, for names and logs
    sig { returns(String) }
    def short_digest = T.must(digest[0, SHORT_DIGEST_LENGTH])

    # @return [String] the registry tag: the digest itself
    sig { returns(String) }
    def tag = digest

    # @return [String] the full image reference, `<registry>/<name>:<tag>`
    sig { returns(String) }
    def ref = "#{@registry}/#{@name}:#{tag}"

    # @return [String] the registry's host — what `docker login` takes
    #   (`ghcr.io` of `ghcr.io/d3mlabs`)
    sig { returns(String) }
    def registry_host = T.must(@registry.split("/").first)

    # @return [Hash{String => String}] the build arg the marker reads
    sig { returns(T::Hash[String, String]) }
    def build_args = { DIGEST_BUILD_ARG => digest }

    # @return [String] what MARKER_PATH holds inside the image
    sig { returns(String) }
    def marker = "name=#{@name}\n#{DIGEST_KEY}=#{digest}\n"

    # @return [String] the platform as dev's key (`linux-x86_64`), variant dropped
    sig { returns(String) }
    def dev_platform = self.class.dev_platform_of(@platform)

    # The pin with the digest stored beside its recipe — what the lock
    # writes, and what from_pin checks.
    #
    # @param pin [Dev::Deps::Dependency] the `:image` pin this was read from
    # @return [Dev::Deps::Dependency]
    sig { params(pin: Dev::Deps::Dependency).returns(Dev::Deps::Dependency) }
    def with_digest(pin)
      pin.with(metadata: pin.metadata.merge(DIGEST_KEY => digest))
    end
  end
end
