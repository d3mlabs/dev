# typed: strict
# frozen_string_literal: true

module Dev
  # Where this dev process is running: on a host, or inside a dev-managed
  # build container.
  #
  # The host dev owns the container's lifecycle (engine, image, start, mounts,
  # credentials); the dev inside owns what runs there. One marker switches
  # between the two: the container service sets DEV_INSIDE_CONTAINER=1 on every
  # container it creates (one-shot runs and the persistent service container,
  # whose env every later `docker exec` inherits), and an inside dev reads it to
  # run project commands directly, skip the host layer in `dev up`, and leave the
  # image-baked build group out of `dev deps install`. Declared by the creator,
  # never inferred from cgroups or /.dockerenv: a container somebody else started
  # is not a dev-managed one unless they said so.
  module ContainerContext
    extend T::Sig

    # The variable name both halves of the contract agree on.
    MARKER = "DEV_INSIDE_CONTAINER"

    # What the container service injects (`-e DEV_INSIDE_CONTAINER=1`).
    MARKER_ENV = T.let({ MARKER => "1" }.freeze, T::Hash[String, String])

    class << self
      extend T::Sig

      # Whether the given environment carries the inside marker.
      #
      # @param env [Hash{String => String}] the environment to read, the
      #   process's own by default
      # @return [Boolean]
      sig { params(env: T::Hash[String, String]).returns(T::Boolean) }
      def inside?(env = ENV.to_h)
        env[MARKER] == "1"
      end
    end
  end
end
