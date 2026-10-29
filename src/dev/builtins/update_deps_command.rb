# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require "dev/command"
require "dev/deps"
require "dev/deps/brew_repository"
require "dev/deps/installer"
require "dev/deps/integration_needs"
require "dev/deps/lockfile"
require "dev/deps/pin_carryover"
require "dev/deps/registry"
require "dev/deps/resolver"
require "dev/deps/scoped_declaration"
require "dev/deps/unlock_set"
require "dev/deps/local_store"
require "dev/environment_image"

module Dev
  module Builtins
    # `dev deps update [<name>…] [--all]`: resolve the dependencies.rb
    # declarations and write the lockfiles — conservatively. A pin whose
    # declaration did not change keeps the lock's version (`bundle install`
    # against an existing Gemfile.lock; PinCarryover has the rule); naming
    # declarations floats those and what they need (`bundle update <gem>`);
    # `--all` floats everything to the registries' current versions.
    # Everything here is derived from the per-call project root, so no
    # collaborators need injecting.
    class UpdateDepsCommand < BuiltinCommand
      extend T::Sig

      # A positional that is not a declaration of the manifest.
      class UnknownDeclarationError < ArgumentError; end
      # `--all` given together with names: the two unlock shapes exclude
      # each other.
      class AllWithNamesError < ArgumentError; end

      ALL_FLAG = "--all"
      # The host and env axes of an image build's `dev deps install`
      # (bin/docker-install-build-deps.sh runs it on Linux under CI=true).
      IMAGE_HOST = "linux"
      IMAGE_ENV = "ci"
      # The pin types that are interpreters: installed before the lockers
      # run, since the lockers' tools run under them.
      INTERPRETER_TYPES = T.let(%i[ruby python].freeze, T::Array[Symbol])

      sig { override.returns(String) }
      def desc = "Resolve dependency constraints and write lockfiles, keeping unchanged pins (<name>… or --all to float)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(ALL_FLAG, desc: "float every pin to the registries' current versions")]

      # dev deps update IS the remediation for a stale manifest — nagging before
      # it would block the very fix being run.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        project_root = project.root

        deps_rb = project_root / "dependencies.rb"
        Dev::Deps.reset!
        Kernel.load(deps_rb.to_s) if deps_rb.exist?

        deps_config = Dev::Deps.last_config || Dev::Deps.define {}
        declarations = deps_config.declarations
        unlock = unlock_set(args, declarations)

        # The needs table: each integration's own manifest, so a declaration
        # pulls the tooling its integration shells to into this project's
        # lock (ADR-0011).
        needs = Dev::Deps::IntegrationNeeds.new.table(Dev::Deps::Registry.integration_classes)
        resolver = Dev::Deps::Resolver.new(
          repositories: Dev::Deps::Registry.repositories(project_root: project_root),
          schemes: Dev::Deps::Registry.schemes,
          needs: needs,
        )

        # The Resolver is a pure function of the declarations and the
        # universe; which pin the lock being written takes — today's or the
        # one on disk — is a question about that lock, answered here against
        # the lock on disk (PinCarryover), once per resolution. The needs'
        # declarations are part of what the resolution answered.
        lockfile = Dev::Deps::Lockfile.new(dir: project_root)
        previous = lockfile.read_for_relock
        carryover = Dev::Deps::PinCarryover.new(schemes: Dev::Deps::Registry.schemes)
        answered = declarations + needs.values.flatten

        # Interpreters before lockers: the lockers run their ecosystem tool
        # under the project's shadowenv (bundle lock under the project Ruby),
        # and a fresh checkout has no .shadowenv.d yet — wrapping alone would
        # solve under the ambient Ruby (dev#76). So the interpreter pins are
        # resolved and installed first, through brew like any formula, which
        # activates them; the Gemfile's ruby directive is the locked version.
        # The carry-over runs on this resolution too: the Ruby that bundle
        # lock runs under must be the one the lock is about to keep.
        # Only the interpreter pins install here — whatever else that
        # resolution carries (an integration's needs) waits for dev up.
        interpreter_declarations = declarations.select { |decl| INTERPRETER_TYPES.include?(decl.integration) }
        interpreters = carryover.apply(
          declarations: answered, previous:, resolved: resolver.resolve(interpreter_declarations), unlock:,
        ).pins.select { |dep| INTERPRETER_TYPES.include?(dep.integration) }
        install_interpreters!(project_root, interpreters) if interpreters.any?

        # Lock, then resolve: integrations whose ecosystem tool owns the
        # whole-set solve (bundler) materialize their tool lockfile first, so
        # the repositories read an already-solved universe. The tool is told
        # what floats; it keeps the rest of its own lockfile.
        lockers = Dev::Deps::Registry.lockers(
          project_root: project_root,
          ruby_version: interpreters.find { |dep| dep.integration == :ruby }&.version,
        )
        declarations.group_by(&:integration).each do |integration, typed_declarations|
          lockers[integration]&.lock(typed_declarations, unlock:)
        end

        outcome = carryover.apply(declarations: answered, previous:, resolved: resolver.resolve(declarations), unlock:)
        # An image's identity is a function of its pin and of dev's template
        # (EnvironmentImage); the lock stores it so a dev with another
        # template refuses the entry as stale instead of re-minting it.
        resolved = Dev::EnvironmentImage.stamp(outcome.pins)
        # Record the manifest digest so the staleness check can tell whether
        # dependencies.rb changed after this resolution (Dev::Deps::Staleness).
        manifest_digest = deps_rb.exist? ? Digest::SHA256.file(deps_rb.to_s).hexdigest : nil
        lockfile.lock(resolved, manifest_digest:)
        report_moves(outcome)
        preflight_bottles(resolved)
        puts "dev: lockfiles updated — now run dev up to install."
      end

      private

      # What the author floats: the names given, `--all`, or nothing.
      #
      # @param args [Cli::ParsedArgs]
      # @param declarations [Array<Dev::Deps::ScopedDeclaration>] the manifest's
      # @return [Dev::Deps::UnlockSet]
      # @raise [AllWithNamesError] when `--all` comes with names
      # @raise [UnknownDeclarationError] when a name is not in the manifest
      sig { params(args: Cli::ParsedArgs, declarations: T::Array[Dev::Deps::ScopedDeclaration]).returns(Dev::Deps::UnlockSet) }
      def unlock_set(args, declarations)
        names = args.positionals
        return Dev::Deps::UnlockSet.none if names.empty? && !args.flag?(ALL_FLAG)
        raise AllWithNamesError, "dev deps update: give names or #{ALL_FLAG}, not both" if names.any? && args.flag?(ALL_FLAG)
        return Dev::Deps::UnlockSet.all if args.flag?(ALL_FLAG)

        known = declarations.map(&:name).uniq
        unknown = names - known
        if unknown.any?
          raise UnknownDeclarationError,
            "dev deps update: dependencies.rb declares no #{unknown.join(", ")} — its declarations are: #{known.sort.join(", ")}"
        end

        Dev::Deps::UnlockSet.new(names:)
      end

      # Say which pins moved, each with why, and which the lock on disk
      # kept — the author asked for a conservative re-lock, so a move they
      # did not ask for has to be visible by name.
      #
      # @param outcome [Dev::Deps::PinCarryover::Outcome]
      # @return [void]
      sig { params(outcome: Dev::Deps::PinCarryover::Outcome).void }
      def report_moves(outcome)
        outcome.moved.each do |move|
          if move.from.nil?
            puts "dev: added #{move.name} #{move.to}"
          else
            puts "dev: moved #{move.name} #{move.from} → #{move.to} (#{move.reason})"
          end
        end
        return if outcome.kept.empty?

        puts "dev: kept #{outcome.kept.size} pin#{"s" unless outcome.kept.size == 1} from deps.lock: " \
          "#{outcome.kept.map(&:name).uniq.join(", ")}"
      end

      # Install the resolved interpreter pins through the brew integration —
      # the same install `dev deps install` would run for them, bottle,
      # verification and activation included — so the lockers that follow
      # run under the interpreters the lock is about to pin.
      #
      # @param project_root [Pathname]
      # @param interpreters [Array<Dev::Deps::Dependency>] the :ruby/:python pins
      # @return [void]
      sig { params(project_root: Pathname, interpreters: T::Array[Dev::Deps::Dependency]).void }
      def install_interpreters!(project_root, interpreters)
        integrations = Dev::Deps::Registry.host_integrations(project_root: project_root, store: Dev::Deps::LocalStore.new)
        integrations.fetch(:brew).install_all(interpreters)
      end

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
