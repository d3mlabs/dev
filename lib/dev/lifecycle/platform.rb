# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # An id outside Platform's set, at a boundary (dev.yml, a manifest, a
    # build name). The message lists the set so the fix is one edit away.
    # Beside the enum rather than inside it: a T::Enum body may hold only
    # its own values.
    class UnknownPlatformError < ArgumentError; end

    # The platform axis of a build: dev's closed id set, one spelling in
    # dev.yml, the DSL, the lock, the CLI and the build name (dev#192, K8).
    # Arch is implied by era — an arch split is a new id, never a suffix.
    # An application host (the game a mod runs in, the server a server
    # build is) is not a platform: it lives in the target's name and its
    # builder. A target with nothing platform-specific declares no
    # `platforms:` and gets no segment, so there is no `noarch` id.
    #
    # Not Dev::Platform (the OS/arch key of a store tree): that names where
    # an artifact *runs*, this names what a toolchain *emits*.
    class Platform < T::Enum
      extend T::Sig

      enums do
        Win64 = new("win64")
        Linux64 = new("linux64")
        Macos = new("macos")
      end

      # What a host of each OS produces natively — the `host` side of the
      # capability check (dev#192, K8). Arch is implied by era, so the OS
      # alone decides: a Mac is the macos era's arm64, a Linux or Windows
      # host the x86_64 one.
      HOST_OS_PLATFORMS = T.let(
        { "darwin" => Macos, "linux" => Linux64, "windows" => Win64 }.freeze,
        T::Hash[String, Platform],
      )

      class << self
        extend T::Sig

        # The platform a host of +os+ produces natively.
        #
        # @param os [String] Dev::Platform.os — "darwin", "linux" or "windows"
        # @return [Platform]
        sig { params(os: String).returns(Platform) }
        def for_host_os(os)
          HOST_OS_PLATFORMS.fetch(os)
        end

        # The platform an id names — the deserialization every boundary
        # goes through.
        #
        # @param id [String] a platform id as written
        # @return [Platform]
        # @raise [UnknownPlatformError]
        sig { params(id: String).returns(Platform) }
        def parse(id)
          try_deserialize(id) || raise(UnknownPlatformError, "unknown platform #{id.inspect} (expected #{ids.join(", ")})")
        end

        # Whether a word is a platform id — what the build grammar and the
        # target-name rule test a segment against.
        #
        # @param word [String]
        # @return [Boolean]
        sig { params(word: String).returns(T::Boolean) }
        def id?(word)
          !try_deserialize(word).nil?
        end

        # Every id, in declaration order.
        #
        # @return [Array<String>]
        sig { returns(T::Array[String]) }
        def ids
          values.map(&:serialize)
        end
      end

      # The id, for a name or a file.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
