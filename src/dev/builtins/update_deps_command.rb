# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require "dev/command"
require "dev/deps"
require "dev/deps/brew_repository"
require "dev/deps/installer"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/deps/resolver"
require "dev/deps/tap_commit_carryover"
require "dev/shadowenv_ruby"

module Dev
  module Builtins
    # `dev deps update`: resolve the dependencies.rb declarations and write
    # the lockfiles. Everything here is derived from the per-call project
    # root, so no collaborators need injecting.
    class UpdateDepsCommand < BuiltinCommand
      extend T::Sig

      # The host and env axes of an image build's `dev deps install`
      # (bin/docker-install-build-deps.sh runs it on Linux under CI=true).
      IMAGE_HOST = "linux"
      IMAGE_ENV = "ci"

      sig { override.returns(String) }
      def desc = "Resolve dependency constraints and write lockfiles"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # dev deps update IS the remediation for a stale manifest — nagging before
      # it would block the very fix being run.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        project_root = project.root
        # Provision before locking: the lockers run their ecosystem tool under
        # the project's shadowenv, and a fresh checkout has no .shadowenv.d
        # yet — wrapping alone would still solve under the ambient Ruby (dev#76).
        # converge!, not ensure!: re-checks the installed ruby's health behind
        # a current lisp (#204).
        ShadowenvRuby.converge!(ruby_version: project.ruby_version, project_root: project_root)

        deps_rb = project_root / "dependencies.rb"
        Dev::Deps.reset!
        Kernel.load(deps_rb.to_s) if deps_rb.exist?

        deps_config = Dev::Deps.last_config || Dev::Deps.define {}
        declarations = deps_config.declarations

        # Lock, then resolve: integrations whose ecosystem tool owns the
        # whole-set solve (bundler) materialize their tool lockfile first, so
        # the repositories read an already-solved universe.
        lockers = Dev::Deps::Registry.lockers(
          project_root: project_root,
          ruby_version_requirement: deps_config.ruby_version_requirement,
        )
        declarations.group_by(&:integration).each do |integration, typed_declarations|
          lockers[integration]&.lock(typed_declarations)
        end

        resolver = Dev::Deps::Resolver.new(
          repositories: Dev::Deps::Registry.repositories(project_root: project_root),
          schemes: Dev::Deps::Registry.schemes,
        )
        lockfile = Dev::Deps::Lockfile.new(dir: project_root)
        # Resolve, then carry provenance: the Resolver is a pure function of
        # the declarations and the universe; which of two equally valid tap
        # commits to write is a question about the lock being written, so it
        # is answered here, against the lock on disk (TapCommitCarryover).
        resolved = Dev::Deps::TapCommitCarryover.new.apply(resolver.resolve(declarations), lockfile.read)
        # Record the manifest digest so the staleness check can tell whether
        # dependencies.rb changed after this resolution (Dev::Deps::Staleness).
        manifest_digest = deps_rb.exist? ? Digest::SHA256.file(deps_rb.to_s).hexdigest : nil
        lockfile.lock(resolved, manifest_digest:)
        preflight_bottles(resolved)
        puts "dev: lockfiles updated — now run dev up to install."
      end

      private

      # Name each formula the image build would compile from source: a
      # missing bottle for the image platform is the usual reason an image
      # build is slow or breaks, and `dev deps update` is the moment the lock
      # learns which formulae those are.
      #
      # Which formulae the image build installs is the installer's selection
      # for that build (bin/docker-install-build-deps.sh: the build group's
      # brew formulae, on a Linux host, under CI=true) — asked of the same
      # predicate, so a formula gated to another host is never named.
      #
      # @param resolved [Array<Dev::Deps::Dependency>] the resolution just locked
      # @return [void]
      sig { params(resolved: T::Array[Dev::Deps::Dependency]).void }
      def preflight_bottles(resolved)
        image_deps = Dev::Deps::Installer.select(
          resolved, env: IMAGE_ENV, host: IMAGE_HOST, groups: [:build], integration_types: [:brew],
        )
        image_deps.each do |dep|
          next unless dep.metadata["format"] == Dev::Deps::BrewRepository::FORMAT_SOURCE

          puts "dev: #{dep.name} has no #{Dev::Deps::BrewRepository::IMAGE_BOTTLE_TAG} bottle — " \
            "the image build compiles it from source."
        end
      end
    end
  end
end
