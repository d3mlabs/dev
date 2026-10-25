# typed: strict
# frozen_string_literal: true

require "rbconfig"

module Dev
  # The OS/arch pair a platform-keyed artifact is valid on — the `platform`
  # of a TreeKey. One spelling per pair, whatever a toolchain calls it
  # (`aarch64` and `arm64` are one architecture; `x64` is `x86_64`), so the
  # host and the container it mounts the data root into never disagree
  # about which subtree is theirs.
  module Platform
    extend T::Sig

    ARCHES = T.let(
      {
        "x86_64" => "x86_64",
        "x64" => "x86_64",
        "amd64" => "x86_64",
        "aarch64" => "arm64",
        "arm64" => "arm64",
      }.freeze,
      T::Hash[String, String],
    )

    class << self
      extend T::Sig

      # This process's platform key.
      #
      # @return [String] e.g. "linux-x86_64", "darwin-arm64"
      sig { returns(String) }
      def current
        key(ruby_platform: RUBY_PLATFORM, host_cpu: RbConfig::CONFIG.fetch("host_cpu"))
      end

      # This process's OS, the key's first half on its own — what the
      # `host:` declaration axis and every OS-shaped default (the data
      # root, the engine) branch on.
      #
      # @param ruby_platform [String] RUBY_PLATFORM (injectable for tests)
      # @return [String] "darwin", "linux", or "windows"
      sig { params(ruby_platform: String).returns(String) }
      def os(ruby_platform: RUBY_PLATFORM)
        case ruby_platform
        when /darwin/ then "darwin"
        when /linux/ then "linux"
        else "windows"
        end
      end

      # The key for a Ruby platform string and host CPU (injectable for tests).
      #
      # @param ruby_platform [String] RUBY_PLATFORM
      # @param host_cpu [String] RbConfig's host_cpu
      # @return [String]
      sig { params(ruby_platform: String, host_cpu: String).returns(String) }
      def key(ruby_platform:, host_cpu:)
        "#{os(ruby_platform:)}-#{ARCHES.fetch(host_cpu, host_cpu)}"
      end

      # The key for a docker platform string (`<os>/<arch>`, as `FROM
      # --platform=` and `docker build --platform` spell it).
      #
      # @param docker_platform [String] e.g. "linux/amd64"
      # @return [String] e.g. "linux-x86_64"
      sig { params(docker_platform: String).returns(String) }
      def from_docker(docker_platform)
        os, arch = docker_platform.split("/", 2)
        "#{os}-#{ARCHES.fetch(arch.to_s, arch.to_s)}"
      end
    end
  end
end
