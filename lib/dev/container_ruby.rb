# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require "dev/container_context"
require "dev/deps/artifact_store"
require "dev/deps/local_store"
require "dev/platform"
require "dev/ruby_build"
require "dev/shadowenv_ruby"

module Dev
  # The project's Ruby, provisioned where it is consumed: inside the build
  # container. The host's Ruby lives under rbenv and is activated by
  # ShadowenvRuby's lisp; a container is another platform entirely, so its
  # Ruby is a ruby-build tree in the artifact store (platform-keyed, built in
  # place because ruby-build bakes its prefix into the binary) with a gem
  # home beside it, both under the mounted data root so they survive the
  # container. A second lisp beside the host one activates them, and only
  # when the container marker is set — on the host it is inert, so one
  # checkout serves both sides.
  class ContainerRuby
    extend T::Sig

    LISP_FILENAME = "510_ruby_container.lisp"
    RUBY_BASE = "~/.dev/ruby"
    GEMS_BASE = "~/.dev/gems"
    RUBY_MARKER = ".dev-ruby"

    # ruby-build exited non-zero.
    class BuildFailedError < StandardError
      extend T::Sig

      # @param version [String] the Ruby that failed to build
      # @param prefix [Pathname] where it was being built
      sig { params(version: String, prefix: Pathname).void }
      def initialize(version:, prefix:)
        super("dev: ruby-build #{version} into #{prefix} failed")
      end
    end

    # The built ruby cannot load a required stdlib extension (its dev library
    # was missing at build time, so ruby-build skipped it).
    class MissingExtensionsError < StandardError
      extend T::Sig

      # @param prefix [Pathname] the built ruby's prefix
      # @param missing [Array<String>] the extensions it cannot load
      sig { params(prefix: Pathname, missing: T::Array[String]).void }
      def initialize(prefix:, missing:)
        super("dev: Ruby at #{prefix} is missing required extensions: #{missing.join(", ")} (brew install #{ShadowenvRuby::RUBY_BUILD_BREW_DEPS.keys.join(" ")} and rerun)")
      end
    end

    # The built ruby runs as a different version than requested (its libruby
    # was hijacked by another on the runtime search path, dev#204).
    class ReportedVersionError < StandardError
      extend T::Sig

      # @param prefix [Pathname] the built ruby's prefix
      # @param version [String] the version requested
      # @param reported [String, nil] the version it runs as
      sig { params(prefix: Pathname, version: String, reported: T.nilable(String)).void }
      def initialize(prefix:, version:, reported:)
        super("dev: Ruby at #{prefix} was built as #{version} but runs as #{reported.inspect}")
      end
    end

    class << self
      extend T::Sig

      # The store key of one container Ruby tree.
      #
      # @param version [String]
      # @param platform [String] the os-arch key
      # @return [Deps::TreeKey]
      sig { params(version: String, platform: String).returns(Deps::TreeKey) }
      def ruby_key(version, platform:)
        Deps::TreeKey.new(base: RUBY_BASE, version: version, marker: RUBY_MARKER, platform: platform)
      end

      # The store key of the gem home paired with one container Ruby.
      #
      # @param version [String]
      # @param platform [String] the os-arch key
      # @return [Deps::TreeKey]
      sig { params(version: String, platform: String).returns(Deps::TreeKey) }
      def gems_key(version, platform:)
        Deps::TreeKey.new(base: GEMS_BASE, version: version, platform: platform)
      end
    end

    # @param store [Deps::ArtifactStore] where the ruby tree and gem home live
    # @param platform [String] the os-arch key the trees are filed under
    # @param builder [RubyBuild] the ruby-build seam
    sig { params(store: Deps::ArtifactStore, platform: String, builder: RubyBuild).void }
    def initialize(store: Deps::LocalStore.new, platform: Platform.current, builder: RubyBuild.new)
      @store = store
      @platform = platform
      @builder = builder
    end

    # Fast path for every command: returns at once when the project's lisp
    # already provides the version over a published tree, else provisions.
    #
    # @param ruby_version [String]
    # @param project_root [Pathname]
    # @return [void]
    sig { params(ruby_version: String, project_root: Pathname).void }
    def ensure!(ruby_version:, project_root:)
      return if provisioned?(ruby_version, project_root: project_root)

      setup!(ruby_version: ruby_version, project_root: project_root)
    end

    # The converge verb: re-verifies a published ruby (version it reports,
    # extensions it loads) and rebuilds it when it has gone bad, then
    # provisions as ensure! does.
    #
    # @param ruby_version [String]
    # @param project_root [Pathname]
    # @return [void]
    sig { params(ruby_version: String, project_root: Pathname).void }
    def converge!(ruby_version:, project_root:)
      root = @store.tree(ruby_key(ruby_version))
      @store.remove_tree(ruby_key(ruby_version)) if root && !healthy?(root, ruby_version)
      setup!(ruby_version: ruby_version, project_root: project_root)
    end

    # Whether the project's container lisp provides +ruby_version+ over a
    # published tree.
    #
    # @param ruby_version [String]
    # @param project_root [Pathname]
    # @return [Boolean]
    sig { params(ruby_version: String, project_root: Pathname).returns(T::Boolean) }
    def provisioned?(ruby_version, project_root:)
      lisp = lisp_path(project_root)
      lisp.file? && lisp.read.include?(provide_form(ruby_version)) && !@store.tree(ruby_key(ruby_version)).nil?
    end

    private

    # Build the ruby if it is not published, make the gem home, write and
    # trust the lisp.
    #
    # @param ruby_version [String]
    # @param project_root [Pathname]
    # @return [void]
    sig { params(ruby_version: String, project_root: Pathname).void }
    def setup!(ruby_version:, project_root:)
      root = @store.tree(ruby_key(ruby_version)) || build!(ruby_version)
      gem_home = @store.workdir(gems_key(ruby_version))
      lisp = lisp_path(project_root)
      lisp.dirname.mkpath
      body = ShadowenvRuby.generate_ruby_lisp(root.to_s, ruby_version, gem_home: gem_home.to_s)
      lisp.write("(when-let ((inside (env/get \"#{ContainerContext::MARKER}\")))\n#{body})\n")
      Dir.chdir(project_root) { system("shadowenv", "trust", out: File::NULL, err: File::NULL) }
    end

    # Build +ruby_version+ into its store tree, verifying it before the marker
    # is written so a bad build is never published.
    #
    # @param ruby_version [String]
    # @return [Pathname] the published tree
    # @raise [BuildFailedError, MissingExtensionsError, ReportedVersionError]
    sig { params(ruby_version: String).returns(Pathname) }
    def build!(ruby_version)
      @store.build_tree(ruby_key(ruby_version)) do |dir|
        raise BuildFailedError.new(version: ruby_version, prefix: dir) unless @builder.call(ruby_version, dir)

        missing = ShadowenvRuby.missing_extensions(dir.to_s)
        raise MissingExtensionsError.new(prefix: dir, missing: missing) unless missing.empty?

        reported = ShadowenvRuby.reported_ruby_version(dir.to_s)
        raise ReportedVersionError.new(prefix: dir, version: ruby_version, reported: reported) unless reported == ruby_version
      end
    end

    # @param root [Pathname] a published ruby tree
    # @param ruby_version [String]
    # @return [Boolean] whether it still loads its extensions and runs as its version
    sig { params(root: Pathname, ruby_version: String).returns(T::Boolean) }
    def healthy?(root, ruby_version)
      ShadowenvRuby.extensions_ok?(root.to_s) && ShadowenvRuby.reported_version_ok?(root.to_s, ruby_version)
    end

    sig { params(ruby_version: String).returns(Deps::TreeKey) }
    def ruby_key(ruby_version) = self.class.ruby_key(ruby_version, platform: @platform)

    sig { params(ruby_version: String).returns(Deps::TreeKey) }
    def gems_key(ruby_version) = self.class.gems_key(ruby_version, platform: @platform)

    sig { params(project_root: Pathname).returns(Pathname) }
    def lisp_path(project_root) = project_root / ".shadowenv.d" / LISP_FILENAME

    sig { params(ruby_version: String).returns(String) }
    def provide_form(ruby_version) = %[(provide "ruby" "#{ruby_version}")]
  end
end
