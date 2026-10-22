# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/debian_host"
require "dev/privileged_steps"
require "dev/process_executor"
require_relative "apt_keyring"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for declared OS packages on Debian-family Linux hosts
    # (apt integration).
    #
    # The converge contract is LinuxEngineProvisioner's, through the same
    # PrivilegedSteps: probe without root first — `dpkg-query` for each
    # package, `dpkg --print-foreign-architectures` for each extra
    # architecture, the keyring (present, and in the form apt reads at that
    # path — see AptKeyring) and sources files for each source — and only
    # when something is missing fetch the keys that need writing (unprivileged:
    # a dead key URL fails before any sudo), open one sudo session, then run
    # each privileged step as its own argv:
    #
    #   1. `dpkg --add-architecture <arch>` per missing architecture
    #   2. per unconverged source: keyring dir, install the staged key (the
    #      vendor's armored key dearmored unless the path is `.asc`), then
    #      either `curl` the deb822 `.sources` file or install a staged
    #      `.list` holding the filled `deb` line
    #   3. `apt-get update` (only when converging — a converged host never
    #      pays for it)
    #   4. `apt-get install -y [--install-recommends] <packages>`, one call
    #      per recommends flavour, under DEBIAN_FRONTEND=noninteractive
    #
    # The probes read the same paths the steps write (SOURCES_DIR, the
    # source's keyring) and apply apt's own acceptance test to the keyring,
    # so install and probe cannot drift. The version that lands is the
    # host's fact: the summary reports `dpkg-query`'s answer per package;
    # the lock only ever said "suite".
    #
    # Headless (no terminal), PrivilegedSteps either rides passwordless sudo
    # or fails fast with SudoRequiredError — the way out is one interactive
    # `dev up` on that host. A non-Linux host skips with a line, as Xcode
    # does off macOS; a Linux without apt-get refuses before any sudo.
    class AptIntegration < Integration
      extend T::Sig

      # No apt-get: the distro is not one dev knows how to install packages on.
      class UnsupportedDistroError < StandardError; end

      # A source's key URL answered nothing.
      class KeyFetchError < StandardError; end

      KEYRINGS_DIR = "/etc/apt/keyrings"
      SOURCES_DIR = "/etc/apt/sources.list.d"
      INSTALLED_STATUS = "install ok installed"

      # One third-party source as declared, with its on-host file names.
      class Source < T::Struct
        extend T::Sig

        const :name, String # the first declaring package; names the files
        const :key, String
        const :keyring, String
        const :sources, T.nilable(String)
        const :deb, T.nilable(String)

        # @return [String] the file apt reads: `.sources` (deb822) or `.list` (one line)
        sig { returns(String) }
        def path
          File.join(SOURCES_DIR, "#{name}.#{sources ? "sources" : "list"}")
        end
      end

      # @param repository [Repository, nil]
      # @param store [ArtifactStore, nil]
      # @param executor [#run, #capture] process seam (dpkg probes)
      # @param host [DebianHost] read-only host facts
      # @param steps [PrivilegedSteps] the sudo contract
      # @param linux [Boolean] whether this host is Linux at all
      # @param root [String] filesystem root the probes read under (tests use a tmpdir)
      # @param out [IO, StringIO] progress lines
      sig do
        params(
          repository: T.nilable(Repository),
          store: T.nilable(ArtifactStore),
          executor: T.untyped,
          host: DebianHost,
          steps: PrivilegedSteps,
          linux: T::Boolean,
          root: String,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(repository:, store:, executor: ProcessExecutor.new, host: DebianHost.new(executor: executor),
        steps: PrivilegedSteps.new(executor: executor, purpose: "install declared apt packages"),
        linux: RUBY_PLATFORM.include?("linux"), root: "/", out: $stderr)
        super(repository:, store:)
        @executor = executor
        @host = host
        @steps = steps
        @linux = linux
        @root = root
        @out = out
      end

      # Converge every declared package: probes, then (only when needed) one
      # sudo session and the steps.
      #
      # @param dependencies [Array<Dependency>] apt deps to install
      # @raise [UnsupportedDistroError] a Linux without apt-get
      # @raise [KeyFetchError] a source's key URL answered nothing
      # @raise [AptKeyring::UnsupportedFormatError] a fetched key apt could not read at its keyring path
      # @raise [PrivilegedSteps::SudoRequiredError] headless and sudo needs a password
      # @raise [PrivilegedSteps::StepFailedError] a step exited nonzero
      sig { override.params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        return if dependencies.empty?

        unless @linux
          @out.puts ">>> apt: not a Linux host, skipping #{dependencies.map(&:name).join(", ")}"
          return
        end
        unless @host.apt_get?
          raise UnsupportedDistroError,
            "no apt-get on this #{@host.distro_id} host — dev only installs OS packages on the Debian family. " \
            "Install #{dependencies.map(&:name).join(", ")} with your distro's tool and re-run `dev up`."
        end

        missing = dependencies.reject { |dep| installed_version(dep.name) }
        archs = dependencies.flat_map { |dep| Array(dep.metadata["architectures"]) }.uniq - foreign_architectures
        sources = unique_sources(dependencies).reject { |source| source_converged?(source) }

        converge(missing, archs, sources) if missing.any? || archs.any? || sources.any?
        dependencies.each { |dep| @out.puts ">>> apt: #{dep.name} #{installed_version(dep.name)}" }
      end

      private

      # @param missing [Array<Dependency>] packages dpkg does not have
      # @param archs [Array<String>] foreign architectures to add
      # @param sources [Array<Source>] sources to write
      # @return [void]
      sig { params(missing: T::Array[Dependency], archs: T::Array[String], sources: T::Array[Source]).void }
      def converge(missing, archs, sources)
        @out.puts ">>> apt: converging #{missing.map(&:name).join(", ")}" if missing.any?
        keys = sources.reject { |source| keyring_converged?(source) }.to_h { |source| [source, fetch_key(source)] }
        @steps.session!
        archs.each { |arch| @steps.step!("sudo", "dpkg", "--add-architecture", arch) }
        sources.each { |source| write_source(source, keys[source]) }
        @steps.step!("sudo", "apt-get", "update")
        missing.partition { |dep| dep.metadata["recommends"] == true }.zip([true, false]).each do |deps, recommends|
          next if deps.empty?

          flags = recommends ? ["--install-recommends"] : []
          @steps.step!(*T.unsafe(["sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", *flags,
                                  *deps.map(&:name)]))
        end
      end

      # The vendor's key, in the form apt reads at the keyring path.
      #
      # @param source [Source]
      # @return [String] bytes to install at +source.keyring+
      # @raise [KeyFetchError] the URL answered nothing
      # @raise [AptKeyring::UnsupportedFormatError] no readable form at that path
      sig { params(source: Source).returns(String) }
      def fetch_key(source)
        fetched = T.unsafe(@executor).capture("curl", "-fsSL", source.key).to_s
        raise KeyFetchError, "apt source #{source.name}: nothing fetched from its key URL #{source.key}" if fetched.empty?

        AptKeyring.content_for(source.keyring, fetched)
      end

      # The key (when it needs writing) and the sources file.
      #
      # @param source [Source]
      # @param key [String, nil] the key bytes to install, nil when the keyring is already right
      # @return [void]
      sig { params(source: Source, key: T.nilable(String)).void }
      def write_source(source, key)
        if key
          @steps.step!("sudo", "install", "-m", "0755", "-d", KEYRINGS_DIR)
          @steps.install_file!(key, source.keyring, mode: "0644")
        end
        if source.sources
          @steps.step!("sudo", "curl", "-fsSL", fill(T.must(source.sources), source), "-o", source.path)
        else
          @steps.install_file!(deb_line(source), source.path, mode: "0644")
        end
      end

      # Keyring right and the sources file present — holding the current
      # line, for a `deb:` source dev wrote itself.
      #
      # @param source [Source]
      # @return [Boolean]
      sig { params(source: Source).returns(T::Boolean) }
      def source_converged?(source)
        path = under_root(source.path)
        return false unless keyring_converged?(source) && File.exist?(path)

        source.deb.nil? || File.read(path) == deb_line(source)
      end

      # Keyring present, in the form apt reads at its path.
      #
      # @param source [Source]
      # @return [Boolean]
      sig { params(source: Source).returns(T::Boolean) }
      def keyring_converged?(source)
        path = under_root(source.keyring)
        File.file?(path) && AptKeyring.accepted?(source.keyring, File.binread(path))
      end

      # @param source [Source] a `deb:` source
      # @return [String] the filled line, newline-terminated
      sig { params(source: Source).returns(String) }
      def deb_line(source)
        "#{fill(T.must(source.deb), source)}\n"
      end

      # Interpolate `%{codename}`, `%{arch}` and `%{keyring}`.
      #
      # @param template [String]
      # @param source [Source]
      # @return [String]
      sig { params(template: String, source: Source).returns(String) }
      def fill(template, source)
        values = { "codename" => @host.codename, "arch" => @host.arch, "keyring" => source.keyring }
        template.gsub(/%\{(\w+)\}/) { values.fetch(T.must(Regexp.last_match(1))) { |k| "%{#{k}}" } }
      end

      # Distinct sources across the deps, each named by its first declarer.
      #
      # @param dependencies [Array<Dependency>]
      # @return [Array<Source>]
      sig { params(dependencies: T::Array[Dependency]).returns(T::Array[Source]) }
      def unique_sources(dependencies)
        seen = T.let({}, T::Hash[T::Hash[String, String], Source])
        dependencies.each do |dep|
          declared = dep.metadata["source"]
          next unless declared.is_a?(Hash)

          seen[declared] ||= Source.new(
            name: dep.name,
            key: declared.fetch("key"),
            keyring: declared.fetch("keyring") { File.join(KEYRINGS_DIR, "#{dep.name}.key") },
            sources: declared["sources"],
            deb: declared["deb"],
          )
        end
        seen.values
      end

      # @param package [String]
      # @return [String, nil] the installed version, nil when not installed
      sig { params(package: String).returns(T.nilable(String)) }
      def installed_version(package)
        status, version = T.unsafe(@executor).capture("dpkg-query", "-W", "-f=${Status} ${Version}", package)
          .strip.split(" ", 4).then { |words| [words[0, 3]&.join(" "), words[3]] }
        status == INSTALLED_STATUS ? version : nil
      end

      # @return [Array<String>] dpkg's enabled foreign architectures
      sig { returns(T::Array[String]) }
      def foreign_architectures
        T.unsafe(@executor).capture("dpkg", "--print-foreign-architectures").split
      end

      # @param path [String] an absolute on-host path
      # @return [String] the same path under the probe root
      sig { params(path: String).returns(String) }
      def under_root(path)
        File.join(@root, path)
      end
    end
  end
end
