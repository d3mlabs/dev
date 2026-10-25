# typed: strict
# frozen_string_literal: true

require "pathname"

require "dev/platform"

module Dev
  # Which platform a build environment is — the fact behind the platform
  # rule (ADR-0007).
  #
  # Everything the build container carries that dev can declare (toolchain,
  # Ruby, gems) dev can also install into the store on any host. The one
  # thing no declaration can install is a different OS/arch, so a
  # container is needed exactly when the host's platform differs from the
  # image's: a Mac runs a linux/amd64 image in a container; a linux-x86_64
  # host *is* that environment and runs its commands directly.
  #
  # An image's platform is its own — a pinned image's is in the pin
  # (EnvironmentImage#dev_platform), and the rule is asked of the command's
  # image (CommandRunner#placement, dev#307). What remains here is the
  # deprecated Dockerfile path's declaration: the first `FROM
  # --platform=…` (d3mlabs/dev#311 removes it). Nothing declared means
  # nothing is known: the host is never taken for the environment, and
  # the container stays the default.
  module EnvironmentPlatform
    extend T::Sig

    # The file the environment is declared in, relative to the project root.
    DOCKERFILE = "Dockerfile"

    # `FROM --platform=<os>/<arch>[/<variant>] image` — the first stage's
    # platform. A build-arg platform (`$BUILDPLATFORM`) is unknown here.
    FROM_PLATFORM = %r{\A\s*FROM\s+--platform=([a-z0-9]+/[a-z0-9]+)(?:/[a-z0-9]+)?\s}i

    class << self
      extend T::Sig

      # Deprecated (d3mlabs/dev#311): the platform the Dockerfile's first FROM declares.
      #
      # @param project_root [Pathname]
      # @return [String, nil] e.g. "linux-x86_64"; nil when no Dockerfile
      #   exists or its first FROM declares no literal platform
      sig { params(project_root: Pathname).returns(T.nilable(String)) }
      def from_dockerfile(project_root)
        dockerfile = project_root / DOCKERFILE
        return nil unless dockerfile.file?

        from = dockerfile.each_line.find { |line| line.match?(/\A\s*FROM\s/i) }
        return nil if from.nil?

        match = FROM_PLATFORM.match(from)
        match && Platform.from_docker(T.must(match[1]))
      end
    end
  end
end
