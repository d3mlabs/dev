# typed: strict
# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require_relative "build_patch_tool"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for the Epic Games Store tooling (egs integration):
    # installs Epic's BuildPatchTool — the one `egs` dependency a project
    # declares — into the store on the host, under `~/.dev/egs/<name>/
    # <digest>/`, from the zip Epic serves.
    #
    # The universe is url-shaped (UrlRepository: the download is the whole
    # address, TOFU-hashed at `dev deps update`), so the locked digest is
    # the version that keys the tree, as a cmake url source's does; the
    # download is verified against it before the tree is published. The
    # tree holds the zip's layout — `Engine/Binaries/<OS>/BuildPatchTool` —
    # and BuildPatchTool.binary names the host's.
    #
    # Pinning the tool is what gives the project its `deploy egs` channel:
    # the store is publishable exactly when the project depends on the tool
    # that publishes to it.
    class EgsIntegration < Integration
      extend T::Sig

      # `curl` could not fetch the tool.
      class DownloadError < StandardError; end

      # The download's digest is not the lock's.
      class IntegrityError < StandardError; end

      # `unzip` could not unpack the download.
      class ExtractionError < StandardError; end

      # The pin carries no digest to verify against.
      class MissingDigestError < StandardError; end

      MARKER_FILE = ".dev-egs-tool"
      ARCHIVE_NAME = "BuildPatchTool.zip"

      class << self
        extend T::Sig

        # The tool lives at `~/.dev/egs/<name>/<digest>`: the dependency's
        # name is the identity, the locked digest the version.
        #
        # @param dep [Dependency] a locked egs dependency
        # @return [TreeKey]
        # @raise [MissingDigestError] for a pin locked without a digest
        sig { override.params(dep: Dependency).returns(TreeKey) }
        def tree_key(dep)
          digest = dep.hash
          raise MissingDigestError, "#{dep.name}: #{dep.metadata["url"]} is locked without a digest — run dev deps update" if digest.nil?

          TreeKey.new(base: "#{Integration::TREES_ROOT}/egs/#{dep.name}", version: digest, marker: MARKER_FILE)
        end
      end

      # Install every egs dependency.
      #
      # @param dependencies [Array<Dependency>] egs deps to install
      # @raise [PartialInstallError] if any dep fails; the rest were attempted
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        failures = collect_failures(dependencies) { |dep| install(dep) }
        raise PartialInstallError, failures if failures.any?
      end

      private

      # An installed tree is a fact; a missing one is two steps — curl and
      # unzip each run with the terminal — and the fact of where it landed.
      #
      # @param dep [Dependency]
      sig { params(dep: Dependency).void }
      def install(dep)
        key = tree_key(dep)
        if (installed = store!.tree(key))
          @ui.note("{{v}} #{dep.name} is installed at #{installed}")
          return
        end

        published = store!.publish_tree(key) do |staging|
          archive = staging / ARCHIVE_NAME
          tool = staging / "tool"
          FileUtils.mkdir_p(tool)

          @ui.step("Downloading #{dep.name} from #{dep.metadata["url"]}") do
            download(dep, archive)
            verify(dep, archive)
          end
          @ui.step("Extracting #{dep.name}") { extract(archive, tool) }
          tool
        end
        @ui.note("{{v}} #{dep.name} installed at #{published}")
      end

      # @param dep [Dependency]
      # @param archive [Pathname]
      # @raise [DownloadError]
      sig { params(dep: Dependency, archive: Pathname).void }
      def download(dep, archive)
        return if system("curl", "-fsSL", "-o", archive.to_s, dep.metadata.fetch("url"))

        raise DownloadError, "download failed for #{dep.metadata["url"]}"
      end

      # @param dep [Dependency]
      # @param archive [Pathname]
      # @raise [IntegrityError]
      sig { params(dep: Dependency, archive: Pathname).void }
      def verify(dep, archive)
        expected = dep.hash
        actual = "SHA256=#{Digest::SHA256.file(archive.to_s).hexdigest}"
        return if actual == expected

        raise IntegrityError, "#{dep.name}: digest mismatch — the lock says #{expected}, the download is #{actual}; run dev deps update"
      end

      # Unpack the zip; the binaries are made executable, since a zip
      # written on Windows carries no mode bits for the Mac and Linux ones.
      #
      # @param archive [Pathname]
      # @param tool [Pathname]
      # @raise [ExtractionError]
      sig { params(archive: Pathname, tool: Pathname).void }
      def extract(archive, tool)
        raise ExtractionError, "unzip of #{archive.basename} failed" unless system("unzip", "-q", "-o", archive.to_s, "-d", tool.to_s)

        BuildPatchTool::BINARIES.each_value do |relative|
          binary = tool / relative
          binary.chmod(0o755) if binary.file?
        end
      end
    end
  end
end
