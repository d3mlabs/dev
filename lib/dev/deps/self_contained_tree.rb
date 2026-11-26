# typed: strict
# frozen_string_literal: true

require "pathname"
require "shellwords"
require_relative "dependency"
require_relative "integration"
require_relative "lockfile"
require_relative "toolchain_exec"

module Dev
  module Deps
    # A self-contained tree: a gh tree that ships its own manifest and lock
    # (`dependencies.rb` and `deps.lock`, {.carried_by?}), which dev
    # installs by converging the tree's dependencies into the tree itself
    # and writing one `bin/<name>` launcher per `exe/<name>`
    # ({#write_launchers!}). The tree exports nothing: no lisp, no gem
    # home, no entry in a project's activation. Its executables run under
    # nothing of the caller's project — only a toolchain keg is shared,
    # and brew owns that, host-level, as for every project. A tree that
    # ships neither file is a plain asset and none of this applies.
    #
    # The property is the tree's by content, not the project's: which
    # files a target ships (`files:`) decides whether its release is
    # self-contained. Converging the dependencies is each ecosystem's
    # work; the one ecosystem today is Ruby's, {GemBundle} — the pinned
    # Ruby, the vendored gems, the binstub-shaped launcher — the gem
    # integration's steps, kept here as the tree's Ruby part until a second
    # ecosystem needs the seam.
    #
    # Whether a tree is *complete* for that install — lock beside the
    # manifest, what its Ruby part needs, an `exe/` to write launchers
    # for, no `bin/` name a launcher would take — is one reading ({#gaps})
    # the gh channel asks for at `dev package`, so an incomplete tree never
    # becomes an immutable asset; the install's own refusals
    # ({GemBundle::NoRubyPinError}, {LauncherCollisionError}) stay as the
    # last line of defence.
    class SelfContainedTree
      extend T::Sig

      # The tree already has a `bin/<name>` the launcher for `exe/<name>`
      # would overwrite: the tree's own bin is its own.
      class LauncherCollisionError < StandardError
        extend T::Sig

        # @param launcher [Pathname] the path the launcher would take
        sig { params(launcher: Pathname).void }
        def initialize(launcher:)
          super("#{launcher} exists — #{COLLISION_RULE}")
        end
      end

      # The two rules a gap names, worded once for the install's refusal
      # and the package-time reading alike.
      PAIR_RULE = "a self-contained tree carries its lock beside its manifest"
      COLLISION_RULE = "a self-contained tree's own bin/ may not carry the name of one of its exe/"

      EXE_DIR = "exe"
      BIN_DIR = "bin"

      class << self
        extend T::Sig

        # Whether a tree is self-contained: it carries the manifest and the
        # lock a project does.
        #
        # @param tree [Pathname]
        # @return [Boolean]
        sig { params(tree: Pathname).returns(T::Boolean) }
        def carried_by?(tree)
          (tree / Integration::MANIFEST_FILE).file? && (tree / Lockfile::DEPS_LOCK_FILE).file?
        end
      end

      # @return [Pathname] the tree's root
      sig { returns(Pathname) }
      attr_reader :root

      # @return [GemBundle] the tree's Ruby part
      sig { returns(GemBundle) }
      attr_reader :gem_bundle

      # @param root [Pathname] the tree, carrying its own `deps.lock`
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
        @lockfile = T.let(Lockfile.new(dir: root), Lockfile)
        @gem_bundle = T.let(GemBundle.new(tree: self), GemBundle)
      end

      # What the tree's own lock pins.
      #
      # @return [Array<Dependency>]
      sig { returns(T::Array[Dependency]) }
      def pins
        @lockfile.read
      end

      # The tree's executables: the files of its `exe/`, sorted. None for a
      # tree without one. `bin/` is dev's output, which is why a tree's
      # executables live in `exe/`.
      #
      # @return [Array<Pathname>]
      sig { returns(T::Array[Pathname]) }
      def executables
        exe = @root / EXE_DIR
        return [] unless exe.directory?

        exe.children.select(&:file?).sort
      end

      # What the tree lacks to be installed self-contained, one clause per
      # gap (`the tree …`), each naming it and the rule; empty when the
      # tree is complete — or when it is a plain asset, shipping neither
      # the manifest nor the lock, which nothing converges. The rules are
      # the install's (GhIntegration#converge_self_contained and
      # {#write_launchers!}), read ahead of it: the lock beside the
      # manifest, what the Ruby part needs ({GemBundle#gaps}), executables
      # to write launchers for, and no `bin/` name a launcher would
      # overwrite.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def gaps
        return [] unless manifest? || lock?
        return ["ships #{Integration::MANIFEST_FILE} without #{Lockfile::DEPS_LOCK_FILE} — #{PAIR_RULE}"] unless lock?
        return ["ships #{Lockfile::DEPS_LOCK_FILE} without #{Integration::MANIFEST_FILE} — #{PAIR_RULE}"] unless manifest?

        gaps = @gem_bundle.gaps
        gaps << "has no #{EXE_DIR}/ — a self-contained tree's executables are its #{EXE_DIR}/, one #{BIN_DIR}/ launcher is written per entry" if executables.empty?
        gaps.concat(collisions.map { |launcher| "carries #{BIN_DIR}/#{launcher.basename} beside #{EXE_DIR}/#{launcher.basename} — #{COLLISION_RULE}" })
      end

      # Write one executable `bin/<name>` launcher per executable, its body
      # the block's for that executable. Nothing is written when any name
      # collides with the tree's own bin/, and nothing at all for a tree
      # with no executables.
      #
      # @yieldparam exe [Pathname] the executable the launcher runs
      # @yieldreturn [String] the launcher's source
      # @return [void]
      # @raise [LauncherCollisionError] when the tree's own bin/ already
      #   carries one of the names
      sig { params(script: T.proc.params(exe: Pathname).returns(String)).void }
      def write_launchers!(&script)
        collision = collisions.first
        raise LauncherCollisionError.new(launcher: collision) if collision

        launchers = executables.to_h { |exe| [exe, launcher_for(exe)] }
        return if launchers.empty?

        (@root / BIN_DIR).mkpath
        launchers.each do |exe, launcher|
          launcher.write(script.call(exe))
          launcher.chmod(0o755)
        end
      end

      # The Ruby part of a self-contained tree, in bundler's words: the Ruby
      # the tree's lock *pins* ({#pinned_ruby}), the gems its `Gemfile.lock`
      # pins *vendored* into the tree ({#vendor!}), and a *binstub*-shaped
      # launcher per executable ({#binstub!}) that runs it under the pinned
      # Ruby wherever the tree is installed.
      #
      # The launcher is bin/dev's sh half and nothing more: it unsets the
      # harness activation ({HARNESS_ACTIVATION_KEYS}) and execs the pinned
      # Ruby by its keg path on `exe/<name>`. It exports nothing and clears
      # nothing else — `GEM_HOME`/`GEM_PATH` are the caller's and pass
      # through to the tool's children (a `dev` it runs in a checkout, the
      # agent's `bundle exec`), as bin/dev keeps them for its own. Selecting
      # the tree's gems is the executable's, in-process, as bin/dev's Ruby
      # half selects dev's: by position relative to `__dir__`, from
      # {VENDOR_DIR} under bundler's layout —
      #
      #   tree = File.expand_path("..", __dir__)
      #   tree_gems = File.join(tree, "vendor/bundle/ruby", RbConfig::CONFIG["ruby_version"])
      #   ruby_own_gems = File.join(RbConfig::CONFIG["rubylibprefix"], "gems", RbConfig::CONFIG["ruby_version"])
      #   Gem.use_paths(tree_gems, [tree_gems, ruby_own_gems])
      #
      # — the tree's vendored gems plus the Ruby's bundled gems, nothing
      # from the environment. `Gem.use_paths` touches no ENV, so the
      # launcher's scrub is the only thing between the caller's env and the
      # tool's children. A launcher that exported bundler's or a gem home's
      # keys into the tool is the shape every regression in the harness-env
      # family took (dev#180 → #274/#306 → #333/#336); spawn_seams_test
      # guards the generated script against it.
      #
      # Which side vendors is the producer's choice. At install, dev vendors
      # the gems into the staging tree under the keg's own bundler (KegExec)
      # before the tree publishes. At release, a target's
      # `packager: { archive: { vendor: true } }` vendors them into the
      # stage under the project's Ruby (ShadowenvExec), so the asset ships
      # them and install writes launchers only ({#vendored?}). Both run the
      # same {#vendor!} through a ToolchainExec.
      class GemBundle
        extend T::Sig

        # The tree's lock pins no Ruby: nothing to run its executables under.
        class NoRubyPinError < StandardError
          extend T::Sig

          # @param tree [Pathname]
          sig { params(tree: Pathname).void }
          def initialize(tree:)
            super("#{tree / Lockfile::DEPS_LOCK_FILE} pins no ruby — a self-contained Ruby tree needs one to run its executables under")
          end
        end

        # `bundle install` into the tree's `vendor/bundle` exited non-zero.
        class VendorError < StandardError; end

        GEMFILE = "Gemfile"
        # Bundler's install path. Bundler lays the gems under it as
        # `ruby/<RbConfig::CONFIG["ruby_version"]>` — a gem home — which is
        # the path the executable selects in-process (see the class comment).
        VENDOR_DIR = "vendor/bundle"
        # The Gemfile groups a vendored tree leaves out, in `BUNDLE_WITHOUT`
        # syntax: bundler's conventional names for a checkout's own tooling.
        WITHOUT_GROUPS = "development:test"

        # What a launcher unsets before it execs, as a tool's entrypoint
        # does (bin/dev's own `unset` line; bin_dev_test keeps that list
        # complete against the locked bundler and self_contained_tree_test
        # keeps this one equal to it). The harness activation — a `bundle
        # exec` the caller runs inside, a CI runner's — would boot the
        # executable inside the caller's bundle instead of the tree's.
        # Nothing else is touched.
        HARNESS_ACTIVATION_KEYS = T.let(
          %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_BIN BUNDLE_BIN_PATH
             BUNDLER_VERSION BUNDLER_SETUP].freeze,
          T::Array[String],
        )

        # @param tree [SelfContainedTree] the tree whose Ruby part this is
        sig { params(tree: SelfContainedTree).void }
        def initialize(tree:)
          @tree = tree
        end

        # The Ruby the tree's lock pins: the keg its executables run under.
        #
        # @return [Dependency] the `ruby` pin
        # @raise [NoRubyPinError] when the lock pins none
        sig { returns(Dependency) }
        def pinned_ruby
          find_pinned_ruby || raise(NoRubyPinError.new(tree: @tree.root))
        end

        # Whether the tree's lock pins a Ruby.
        #
        # @return [Boolean]
        sig { returns(T::Boolean) }
        def ruby_pinned?
          !find_pinned_ruby.nil?
        end

        # What the tree lacks for its Ruby part to install, in the tree's
        # gap wording (`the tree …`): the Ruby its executables and gems run
        # under. One clause, or none when the lock pins one.
        #
        # @return [Array<String>]
        sig { returns(T::Array[String]) }
        def gaps
          return [] if ruby_pinned?

          ["pins no ruby in #{Lockfile::DEPS_LOCK_FILE} — its executables and gems run under the Ruby its lock pins"]
        end

        # Whether the tree has gems to run under: a Gemfile beside the lock.
        #
        # @return [Boolean]
        sig { returns(T::Boolean) }
        def gems?
          (@tree.root / GEMFILE).file?
        end

        # Whether the tree's gems are already in it — vendored at release.
        #
        # @return [Boolean]
        sig { returns(T::Boolean) }
        def vendored?
          (@tree.root / VENDOR_DIR).directory?
        end

        # Install the tree's gems into its `vendor/bundle`, frozen to its
        # Gemfile.lock, under the toolchain the seam runs. A tree without a
        # Gemfile has no gems to vendor and this does nothing.
        #
        # Runtime groups only ({WITHOUT_GROUPS}): the installed tree is a
        # deployed tool, and its Gemfile's development and test groups are
        # the producer's checkout tooling (linters, type checkers, test
        # frameworks), never run from the tree. Vendoring them is also what
        # made installs need a C toolchain: ai-flow's own gems are pure
        # Ruby, and the one native extension in its lock came in through
        # rubocop.
        #
        # @param exec [ToolchainExec] the Ruby to bundle under
        # @param cache [Pathname, nil] bundler's download cache (the store's
        #   bundler tool cache); nil leaves bundler its own
        # @return [void]
        # @raise [VendorError] when `bundle install` fails
        sig { params(exec: ToolchainExec, cache: T.nilable(Pathname)).void }
        def vendor!(exec:, cache: nil)
          return unless gems?

          # The bundle install's own env, for that one child: the tree's
          # Gemfile, its own path, frozen to its lock, nothing shared.
          env = T.let(
            {
              "BUNDLE_GEMFILE" => (@tree.root / GEMFILE).to_s,
              "BUNDLE_PATH" => (@tree.root / VENDOR_DIR).to_s,
              "BUNDLE_FROZEN" => "true",
              "BUNDLE_WITHOUT" => WITHOUT_GROUPS,
              "BUNDLE_DISABLE_SHARED_GEMS" => "true",
            },
            T::Hash[String, T.nilable(String)],
          )
          env.merge!("BUNDLE_GLOBAL_GEM_CACHE" => "true", "BUNDLE_USER_CACHE" => cache.to_s) if cache
          _out, err, status = exec.capture3("bundle", "install", env:)
          return if status.success?

          raise VendorError, "bundle install into #{@tree.root / VENDOR_DIR} failed: #{err.strip}"
        end

        # Write the tree's launchers as binstubs: one sh script per
        # executable that resolves the tree from its own location (so a
        # tree published from staging keeps working at its final path),
        # unsets the harness activation, and execs the pinned Ruby on
        # `exe/<name>`. The same script whether the tree has gems or not:
        # finding them is the executable's (class comment).
        #
        # @param ruby [Pathname] the pinned Ruby's executable (`<keg>/bin/ruby`)
        # @return [void]
        # @raise [LauncherCollisionError] when the tree's own bin/ already
        #   carries one of the names
        sig { params(ruby: Pathname).void }
        def binstub!(ruby:)
          @tree.write_launchers! { |exe| binstub_script(exe, ruby) }
        end

        private

        # @return [Dependency, nil] the lock's `ruby` pin, if it has one
        sig { returns(T.nilable(Dependency)) }
        def find_pinned_ruby
          @tree.pins.find { |dep| dep.integration == :ruby }
        end

        # The binstub's source: bin/dev's sh half for this tree. No `export`
        # and no gem-env key, ever — spawn_seams_test reads the output.
        #
        # @param exe [Pathname] the executable the binstub runs
        # @param ruby [Pathname] the pinned Ruby's executable
        # @return [String]
        sig { params(exe: Pathname, ruby: Pathname).returns(String) }
        def binstub_script(exe, ruby)
          name = exe.basename
          <<~SH
            #!/bin/sh
            # Generated by dev: #{name} under this tree's own Ruby. The executable selects the tree's gems itself.
            tree="$(cd "$(dirname "$0")/.." && pwd -P)"
            unset #{HARNESS_ACTIVATION_KEYS.join(" ")}
            exec #{ruby.to_s.shellescape} "$tree/#{EXE_DIR}/#{name}" "$@"
          SH
        end
      end

      private

      # @return [Boolean] whether the tree ships its manifest
      sig { returns(T::Boolean) }
      def manifest?
        (@root / Integration::MANIFEST_FILE).file?
      end

      # @return [Boolean] whether the tree ships its lock
      sig { returns(T::Boolean) }
      def lock?
        (@root / Lockfile::DEPS_LOCK_FILE).file?
      end

      # The `bin/<name>` the tree already carries for an `exe/<name>` — the
      # paths a launcher would overwrite, in executable order.
      #
      # @return [Array<Pathname>]
      sig { returns(T::Array[Pathname]) }
      def collisions
        executables.map { |exe| launcher_for(exe) }.select(&:exist?)
      end

      # @param exe [Pathname] an executable
      # @return [Pathname] the path its launcher takes
      sig { params(exe: Pathname).returns(Pathname) }
      def launcher_for(exe)
        @root / BIN_DIR / exe.basename
      end
    end
  end
end
