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
    # A tool tree's closure: the Ruby its own `deps.lock` pins and the gems
    # its `Gemfile.lock` pins, materialized into the tree so its executables
    # run under them wherever the tree is installed, and under nothing of
    # the caller's.
    #
    # A gh tree that carries `dependencies.rb` and `deps.lock` is a tool
    # with a closure ({.carried_by?}). Its executables are its `exe/`; the
    # closure lands beside them — the gems in `vendor/bundle` ({#vendor!}),
    # one `bin/<name>` wrapper per executable ({#wrap!}). The tree exports
    # nothing: no lisp, no gem home, no entry in a project's activation; it
    # shares only the Ruby keg, which brew owns. The closure lives in the
    # tree and goes with it.
    #
    # The wrapper is bin/dev's sh half and nothing more: it unsets the
    # harness activation ({HARNESS_ACTIVATION_KEYS}) and execs the locked
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
    # — the tree's closure plus the Ruby's bundled gems, nothing from the
    # environment. `Gem.use_paths` touches no ENV, so the wrapper's scrub
    # is the only thing between the caller's env and the tool's children.
    # A wrapper that exported bundler's or a gem home's keys into the tool
    # is the shape every regression in the harness-env family took
    # (dev#180 → #274/#306 → #333/#336); spawn_seams_test guards the
    # generated script against it.
    #
    # Which side vendors is the producer's choice. At install, dev vendors
    # the gems into the staging tree under the keg's own bundler (KegExec)
    # before the tree publishes. At release, a target's
    # `packager: { archive: { vendor: true } }` vendors them into the
    # install under the project's Ruby (ShadowenvExec), so the asset ships
    # them and install writes wrappers only ({#vendored?}). Both run the
    # same {#vendor!} through a ToolchainExec.
    #
    # Whether a tree is *complete* for that install — lock beside the
    # manifest, a Ruby pin, an `exe/` to wrap, no `bin/` name an `exe/`
    # would take — is one reading ({#gaps}) the gh channel asks for at
    # `dev package`, so an incomplete tree never becomes an immutable
    # asset; the install's own refusals ({NoRubyPinError},
    # {WrapperCollisionError}) stay as the last line of defence.
    class ToolClosure
      extend T::Sig

      # The tree's lock pins no Ruby: nothing to run its executables under.
      class NoRubyPinError < StandardError
        extend T::Sig

        # @param tree [Pathname]
        sig { params(tree: Pathname).void }
        def initialize(tree:)
          super("#{tree / Lockfile::DEPS_LOCK_FILE} pins no ruby — a tool tree's closure needs one to run its executables under")
        end
      end

      # `bundle install` into the tree's `vendor/bundle` exited non-zero.
      class VendorError < StandardError; end

      # The tree already has a `bin/<name>` the wrapper for `exe/<name>`
      # would overwrite: the tree's own bin is its own.
      class WrapperCollisionError < StandardError
        extend T::Sig

        # @param wrapper [Pathname] the path the wrapper would take
        sig { params(wrapper: Pathname).void }
        def initialize(wrapper:)
          super("#{wrapper} exists — #{COLLISION_RULE}")
        end
      end

      # The two rules a gap names, worded once for the install's refusal
      # and the package-time reading alike.
      PAIR_RULE = "a self-contained tree carries its lock beside its manifest"
      COLLISION_RULE = "a tool tree's own bin/ may not carry the name of one of its exe/"

      GEMFILE = "Gemfile"
      # Bundler's install path. Bundler lays the gems under it as
      # `ruby/<RbConfig::CONFIG["ruby_version"]>` — a gem home — which is
      # the path the executable selects in-process (see the class comment).
      VENDOR_DIR = "vendor/bundle"
      EXE_DIR = "exe"
      BIN_DIR = "bin"

      # What a wrapper unsets before it execs, as a tool's entrypoint does
      # (bin/dev's own `unset` line; bin_dev_test keeps that list complete
      # against the locked bundler and tool_closure_test keeps this one
      # equal to it). The harness activation — a `bundle exec` the caller
      # runs inside, a CI runner's — would boot the executable inside the
      # caller's bundle instead of the tree's. Nothing else is touched.
      HARNESS_ACTIVATION_KEYS = T.let(
        %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_BIN BUNDLE_BIN_PATH
           BUNDLER_VERSION BUNDLER_SETUP].freeze,
        T::Array[String],
      )

      class << self
        extend T::Sig

        # Whether a tree is a tool with a closure: it carries the manifest
        # and the lock a project does.
        #
        # @param tree [Pathname]
        # @return [Boolean]
        sig { params(tree: Pathname).returns(T::Boolean) }
        def carried_by?(tree)
          (tree / Integration::MANIFEST_FILE).file? && (tree / Lockfile::DEPS_LOCK_FILE).file?
        end
      end

      # @return [Pathname] the tree
      sig { returns(Pathname) }
      attr_reader :tree

      # @param tree [Pathname] the tool tree, carrying its own `deps.lock`
      sig { params(tree: Pathname).void }
      def initialize(tree:)
        @tree = tree
        @lockfile = T.let(Lockfile.new(dir: tree), Lockfile)
      end

      # The Ruby the tree's lock pins: the keg its executables run under.
      #
      # @return [Dependency] the `ruby` pin
      # @raise [NoRubyPinError] when the lock pins none
      sig { returns(Dependency) }
      def ruby_pin
        find_ruby_pin || raise(NoRubyPinError.new(tree: @tree))
      end

      # Whether the tree's lock pins a Ruby.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def ruby_pinned?
        !find_ruby_pin.nil?
      end

      # Whether the tree has gems to run under: a Gemfile beside the lock.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def gems?
        (@tree / GEMFILE).file?
      end

      # What the tree lacks to be installed self-contained, one clause per
      # gap (`the tree …`), each naming it and the rule; empty when the
      # tree is complete — or when it is a plain asset, shipping neither
      # the manifest nor the lock, which nothing converges. The rules are
      # the install's (GhIntegration#materialize_closure and {#wrap!}),
      # read ahead of it: the lock beside the manifest, a Ruby for the
      # executables and the gems to run under, executables to write
      # launchers for, and no `bin/` name a launcher would overwrite.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def gaps
        return [] unless manifest? || lock?
        return ["ships #{Integration::MANIFEST_FILE} without #{Lockfile::DEPS_LOCK_FILE} — #{PAIR_RULE}"] unless lock?
        return ["ships #{Lockfile::DEPS_LOCK_FILE} without #{Integration::MANIFEST_FILE} — #{PAIR_RULE}"] unless manifest?

        gaps = T.let([], T::Array[String])
        gaps << "pins no ruby in #{Lockfile::DEPS_LOCK_FILE} — its executables and gems run under the Ruby its lock pins" unless ruby_pinned?
        gaps << "has no #{EXE_DIR}/ — a self-contained tree's executables are its #{EXE_DIR}/, one #{BIN_DIR}/ launcher is written per entry" if executables.empty?
        gaps.concat(collisions.map { |wrapper| "carries #{BIN_DIR}/#{wrapper.basename} beside #{EXE_DIR}/#{wrapper.basename} — #{COLLISION_RULE}" })
      end

      # Whether the tree's gems are already in it — vendored at release.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def vendored?
        (@tree / VENDOR_DIR).directory?
      end

      # The tree's executables: the files of its `exe/`, sorted. None for a
      # tree without one.
      #
      # @return [Array<Pathname>]
      sig { returns(T::Array[Pathname]) }
      def executables
        exe = @tree / EXE_DIR
        return [] unless exe.directory?

        exe.children.select(&:file?).sort
      end

      # Install the tree's gems into its `vendor/bundle`, frozen to its
      # Gemfile.lock, under the toolchain the seam runs. A tree without a
      # Gemfile has no gems to vendor and this does nothing.
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
            "BUNDLE_GEMFILE" => (@tree / GEMFILE).to_s,
            "BUNDLE_PATH" => (@tree / VENDOR_DIR).to_s,
            "BUNDLE_FROZEN" => "true",
            "BUNDLE_DISABLE_SHARED_GEMS" => "true",
          },
          T::Hash[String, T.nilable(String)],
        )
        env.merge!("BUNDLE_GLOBAL_GEM_CACHE" => "true", "BUNDLE_USER_CACHE" => cache.to_s) if cache
        _out, err, status = exec.capture3("bundle", "install", env:)
        return if status.success?

        raise VendorError, "bundle install into #{@tree / VENDOR_DIR} failed: #{err.strip}"
      end

      # Write one `bin/<name>` wrapper per executable: a sh script that
      # resolves the tree from its own location (so a tree published from
      # staging keeps working at its final path), unsets the harness
      # activation, and execs the locked Ruby on `exe/<name>`. The same
      # script whether the tree has gems or not: finding them is the
      # executable's (class comment).
      #
      # @param ruby [Pathname] the locked Ruby's executable (`<keg>/bin/ruby`)
      # @return [void]
      # @raise [WrapperCollisionError] when the tree's own bin/ already
      #   carries one of the names
      sig { params(ruby: Pathname).void }
      def wrap!(ruby:)
        collision = collisions.first
        raise WrapperCollisionError.new(wrapper: collision) if collision

        wrappers = executables.to_h { |exe| [exe, wrapper_for(exe)] }
        return if wrappers.empty?

        (@tree / BIN_DIR).mkpath
        wrappers.each do |exe, wrapper|
          wrapper.write(wrapper_script(exe, ruby))
          wrapper.chmod(0o755)
        end
      end

      private

      # @return [Boolean] whether the tree ships its manifest
      sig { returns(T::Boolean) }
      def manifest?
        (@tree / Integration::MANIFEST_FILE).file?
      end

      # @return [Boolean] whether the tree ships its lock
      sig { returns(T::Boolean) }
      def lock?
        (@tree / Lockfile::DEPS_LOCK_FILE).file?
      end

      # @return [Dependency, nil] the lock's `ruby` pin, if it has one
      sig { returns(T.nilable(Dependency)) }
      def find_ruby_pin
        @lockfile.read.find { |dep| dep.integration == :ruby }
      end

      # The `bin/<name>` the tree already carries for an `exe/<name>` — the
      # paths a wrapper would overwrite, in executable order.
      #
      # @return [Array<Pathname>]
      sig { returns(T::Array[Pathname]) }
      def collisions
        executables.map { |exe| wrapper_for(exe) }.select(&:exist?)
      end

      # @param exe [Pathname] an executable
      # @return [Pathname] the path its wrapper takes
      sig { params(exe: Pathname).returns(Pathname) }
      def wrapper_for(exe)
        @tree / BIN_DIR / exe.basename
      end

      # The wrapper's source: bin/dev's sh half for this tree. No `export`
      # and no gem-env key, ever — spawn_seams_test reads the output.
      #
      # @param exe [Pathname] the executable the wrapper runs
      # @param ruby [Pathname] the locked Ruby's executable
      # @return [String]
      sig { params(exe: Pathname, ruby: Pathname).returns(String) }
      def wrapper_script(exe, ruby)
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
  end
end
