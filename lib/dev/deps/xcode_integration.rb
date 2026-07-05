# frozen_string_literal: true

require "pathname"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for the pinned Xcode toolchain (xcode integration).
    #
    # Inherently darwin-scoped: Xcode only exists on macOS, so on any other
    # host install_all is a no-op and declarations are safe without explicit
    # host gating.
    #
    # Install contract — optimistic attempt everywhere, fail fast only at a
    # genuine prompt:
    #   1. /Applications/Xcode-<version>.app already present -> done. This is
    #      the normal case: the pin is pre-installed interactively once during
    #      machine/runner bring-up (Apple ID 2FA + sudo happen there, never in
    #      an unattended run), and the version-named path is untouched by App
    #      Store auto-update and macOS updates.
    #   2. Missing -> shell to `xcodes install <version>` (the xcodes CLI is a
    #      :build brew dep of consuming repos, so build-first install ordering
    #      guarantees it exists here). With a TTY, stdio is inherited so any
    #      prompt (Apple ID, 2FA, sudo, license) flows to the human. Headless,
    #      stdin is /dev/null: unattended installs succeed when the standing
    #      state allows (valid keychain session or XCODES_USERNAME/
    #      XCODES_PASSWORD, passwordless sudo); a genuinely-required prompt
    #      reads EOF and fails immediately — never a hung job — and the error
    #      carries the remediation menu.
    #   3. Publish DEVELOPER_DIR via shadowenv so every project command rides
    #      the pin.
    class XcodeIntegration < Integration
      class XcodesMissingError < StandardError; end
      class InstallError < StandardError; end

      INSTALL_ROOT = "/Applications"

      # The version-named app bundle the pin installs to. xcodes' default
      # naming, chosen precisely because nothing auto-updates it in place.
      #
      # @param version [String] pinned Xcode version
      # @param root [String] install root (tests point this at a tmpdir)
      # @return [String]
      def self.app_path(version, root: INSTALL_ROOT)
        File.join(root, "Xcode-#{version}.app")
      end

      # The DEVELOPER_DIR for a pinned version.
      #
      # @param version [String] pinned Xcode version
      # @param root [String] install root (tests point this at a tmpdir)
      # @return [String]
      def self.developer_dir(version, root: INSTALL_ROOT)
        File.join(app_path(version, root:), "Contents", "Developer")
      end

      # @param repository [Repository]
      # @param cache [Cache]
      # @param project_root [String, Pathname, nil] repo root (shadowenv lives there)
      # @param install_root [String] where Xcode bundles live (tests use a tmpdir)
      def initialize(repository:, cache:, project_root: nil, install_root: INSTALL_ROOT)
        super(repository:, cache:)
        @project_root = project_root && Pathname(project_root)
        @install_root = install_root
      end

      # Install all xcode pins (in practice: one per project).
      #
      # @param dependencies [Array<Dependency>] xcode deps to install
      def install_all(dependencies)
        unless darwin?
          puts ">>> xcode: not a macOS host, skipping" if dependencies.any?
          return
        end

        dependencies.each { |dep| install(dep) }
      end

      private

      attr_reader :project_root, :install_root

      # @param dep [Dependency]
      def install(dep)
        app = self.class.app_path(dep.version, root: install_root)
        if Dir.exist?(app)
          puts ">>> xcode #{dep.version} already installed at #{app}"
        else
          install_via_xcodes(dep.version)
        end
        publish_developer_dir(dep.version)
      end

      # @param version [String]
      # @raise [XcodesMissingError] when the xcodes CLI is absent
      # @raise [InstallError] when the install fails (with the headless remediation menu)
      def install_via_xcodes(version)
        unless xcodes_available?
          raise XcodesMissingError,
                "xcode #{version}: the xcodes CLI is not installed. " \
                "Declare it in dependencies.rb — group :build { brew \"xcodes\", tap: \"xcodesorg/made\" } — and run dev up."
        end

        puts ">>> Installing Xcode #{version} via xcodes (this downloads several GB)"
        return if run_xcodes_install(version) && Dir.exist?(self.class.app_path(version, root: install_root))

        raise InstallError, install_failure_message(version)
      end

      # Run `xcodes install`, wiring stdio by context: interactive runs inherit
      # the terminal so prompts reach the human; headless runs read EOF at any
      # prompt and fail immediately instead of hanging the job.
      #
      # @param version [String]
      # @return [Boolean] whether xcodes exited 0
      def run_xcodes_install(version)
        argv = ["xcodes", "install", version, "--directory", install_root]
        if interactive?
          system(*argv)
        else
          system(*argv, in: File::NULL)
        end
      end

      # @param version [String]
      # @return [String]
      def install_failure_message(version)
        if interactive?
          "xcodes install #{version} failed — see its output above."
        else
          "xcodes install #{version} failed in a headless run — it likely needed a prompt " \
            "(Apple ID/2FA or sudo). Remediations: pre-install the pin interactively on this " \
            "machine (xcodes install #{version}), or provide XCODES_USERNAME/XCODES_PASSWORD " \
            "plus passwordless sudo for unattended installs."
        end
      end

      # Publish DEVELOPER_DIR into the project's shadowenv so commands ride the
      # pin. Skipped when dev has no project context (nothing to publish into).
      #
      # @param version [String]
      def publish_developer_dir(version)
        return unless project_root

        require "shadowenv_xcode"
        developer_dir = self.class.developer_dir(version, root: install_root)
        return if ShadowenvXcode.provisioned?(developer_dir, project_root: project_root)

        ShadowenvXcode.setup!(project_root: project_root, version: version, developer_dir: developer_dir)
        puts ">>> xcode #{version}: DEVELOPER_DIR published via shadowenv (#{developer_dir})"
      end

      # @return [Boolean]
      def darwin?
        RUBY_PLATFORM.include?("darwin")
      end

      # @return [Boolean]
      def interactive?
        $stdin.tty?
      end

      # @return [Boolean]
      def xcodes_available?
        system("command -v xcodes >/dev/null 2>&1")
      end
    end
  end
end
