# typed: strict
# frozen_string_literal: true

require "pathname"

require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/platform"

module Dev
  # Which platform a project's build environment is, and whether this host
  # is it — the fact behind the platform rule.
  #
  # Everything the build container carries that dev can declare (toolchain,
  # Ruby, gems) dev can also install into the store on any host. The one
  # thing no declaration can install is a different OS/arch, so the
  # container is needed exactly when the host's platform differs from the
  # environment's: a Mac runs the linux/amd64 environment in a container;
  # a linux-x86_64 host *is* that environment and runs it directly.
  #
  # The environment's platform is the lock's `image` pin's (dev#277) — the
  # image is the pin, and its platform is in it. A project still on the
  # deprecated Dockerfile path declares it on the first `FROM --platform=…`
  # (d3mlabs/dev#311 removes that read). Nothing declared means nothing is
  # known: the host is never taken for the environment, and the container
  # stays the default.
  module EnvironmentPlatform
    extend T::Sig

    # The file the environment is declared in, relative to the project root.
    DOCKERFILE = "Dockerfile"

    # `FROM --platform=<os>/<arch>[/<variant>] image` — the first stage's
    # platform. A build-arg platform (`$BUILDPLATFORM`) is unknown here.
    FROM_PLATFORM = %r{\A\s*FROM\s+--platform=([a-z0-9]+/[a-z0-9]+)(?:/[a-z0-9]+)?\s}i

    class << self
      extend T::Sig

      # The platform the project's environment declares, as a dev platform
      # key: the lock's image pins first, the Dockerfile as the fallback.
      #
      # @param project_root [Pathname] the checkout holding deps.lock
      # @return [String, nil] e.g. "linux-x86_64"; nil when the image pins
      #   disagree (d3mlabs/dev#307 decides which a command runs in), or with
      #   no pin, when no Dockerfile exists or its first FROM declares no
      #   literal platform
      # @raise [Deps::Lockfile::RetiredBuildLockError] when build-deps.lock is still present
      sig { params(project_root: Pathname).returns(T.nilable(String)) }
      def declared(project_root:)
        pins = Deps::Lockfile.new(dir: project_root).read.select { |pin| pin.integration == :image }
        return pinned(pins) if pins.any?

        from_dockerfile(project_root)
      end

      # @param pins [Array<Deps::Dependency>] the lock's image pins, at least one
      # @return [String, nil] the one platform they share, or nil when they differ
      sig { params(pins: T::Array[Deps::Dependency]).returns(T.nilable(String)) }
      def pinned(pins)
        platforms = pins.map { |pin| EnvironmentImage.dev_platform_of(pin.metadata.fetch("platform")) }.uniq
        platforms.size == 1 ? platforms.first : nil
      end

      # Deprecated (d3mlabs/dev#311): the platform the Dockerfile's first FROM declares.
      #
      # @param project_root [Pathname]
      # @return [String, nil]
      sig { params(project_root: Pathname).returns(T.nilable(String)) }
      def from_dockerfile(project_root)
        dockerfile = project_root / DOCKERFILE
        return nil unless dockerfile.file?

        from = dockerfile.each_line.find { |line| line.match?(/\A\s*FROM\s/i) }
        return nil if from.nil?

        match = FROM_PLATFORM.match(from)
        match && Platform.from_docker(T.must(match[1]))
      end

      # Whether this host is the build environment: the project declares a
      # platform and it is the host's.
      #
      # @param project_root [Pathname]
      # @param host [String] the host's platform key (Platform.current)
      # @return [Boolean]
      sig { params(project_root: Pathname, host: String).returns(T::Boolean) }
      def host_is_environment?(project_root:, host: Platform.current)
        declared(project_root:) == host
      end
    end
  end
end
