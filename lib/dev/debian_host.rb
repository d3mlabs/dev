# typed: strict
# frozen_string_literal: true

require "dev/process_executor"

module Dev
  # Read-only facts about a Debian-family Linux host that an apt-driven
  # converge needs: which executables are on PATH, whether apt-get is one of
  # them, the distro id and codename (`/etc/os-release`) that third-party apt
  # sources key on, and dpkg's architecture. No root, no side effects.
  class DebianHost
    extend T::Sig

    OS_RELEASE = "/etc/os-release"

    # @param executor [#capture] process seam, for dpkg
    # @param path [String] PATH to resolve executables on
    # @param os_release_path [String] the distro's os-release file
    sig { params(executor: T.untyped, path: String, os_release_path: String).void }
    def initialize(executor: ProcessExecutor.new, path: ENV.fetch("PATH", ""), os_release_path: OS_RELEASE)
      @executor = executor
      @path = path
      @os_release_path = os_release_path
    end

    # @param name [String]
    # @return [String, nil] the first executable +name+ on PATH
    sig { params(name: String).returns(T.nilable(String)) }
    def which(name)
      @path.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        candidate = File.join(dir, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    # @return [Boolean] whether this is a host apt-get can install on
    sig { returns(T::Boolean) }
    def apt_get?
      !which("apt-get").nil?
    end

    # @return [String] os-release ID ("ubuntu", "debian", …), "unknown" when unreadable
    sig { returns(String) }
    def distro_id
      os_release["ID"] || "unknown"
    end

    # @return [String] os-release VERSION_CODENAME, "stable" when unreadable
    sig { returns(String) }
    def codename
      os_release["VERSION_CODENAME"] || "stable"
    end

    # @return [String] dpkg's native architecture ("amd64", "arm64")
    sig { returns(String) }
    def arch
      T.unsafe(@executor).capture("dpkg", "--print-architecture").strip
    end

    private

    # @return [Hash{String => String}] os-release key/values, unquoted
    sig { returns(T::Hash[String, String]) }
    def os_release
      return {} unless File.exist?(@os_release_path)

      File.readlines(@os_release_path, chomp: true).each_with_object({}) do |line, acc|
        key, value = line.split("=", 2)
        next if key.nil? || value.nil?

        acc[key] = value.delete_prefix('"').delete_suffix('"')
      end
    end
  end
end
