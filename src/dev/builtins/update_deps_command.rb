# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require "dev/builtin_body"
require "dev/deps"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/deps/resolver"

module Dev
  module Builtins
    # `dev update-deps`: resolve the dependencies.rb declarations and write
    # the lockfiles. Everything here is derived from the per-call project
    # root, so no collaborators need injecting.
    class UpdateDepsCommand
      extend T::Sig
      include BuiltinBody

      sig { override.returns(String) }
      def desc = "Resolve dependency constraints and write lockfiles"

      # update-deps IS the remediation for a stale manifest — nagging before
      # it would block the very fix being run.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        deps_rb = context.project_root / "dependencies.rb"
        Dev::Deps.reset!
        Kernel.load(deps_rb.to_s) if deps_rb.exist?

        deps_config = Dev::Deps.last_config || Dev::Deps.define {}
        resolver = Dev::Deps::Resolver.new(
          repositories: Dev::Deps::Registry.repositories(
            project_root: context.project_root,
            ruby_version_requirement: deps_config.ruby_version_requirement,
          ),
        )
        lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
        resolved = resolver.resolve(deps_config.declarations)
        # Record the manifest digest so the staleness check can tell whether
        # dependencies.rb changed after this resolution (Dev::Deps::Staleness).
        manifest_digest = deps_rb.exist? ? Digest::SHA256.file(deps_rb.to_s).hexdigest : nil
        lockfile.lock(resolved, manifest_digest:)
        puts "dev: lockfiles updated — now run dev up to install."
      end
    end
  end
end
