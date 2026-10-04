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

      # The key for a Ruby platform string and host CPU (injectable for tests).
      #
      # @param ruby_platform [String] RUBY_PLATFORM
      # @param host_cpu [String] RbConfig's host_cpu
      # @return [String]
      sig { params(ruby_platform: String, host_cpu: String).returns(String) }
      def key(ruby_platform:, host_cpu:)
        os = case ruby_platform
        when /darwin/ then "darwin"
        when /linux/ then "linux"
        else "windows"
        end
        "#{os}-#{ARCHES.fetch(host_cpu, host_cpu)}"
      end
    end
  end
end
