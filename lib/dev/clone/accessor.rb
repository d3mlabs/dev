# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/clone/repo_spec"
require "dev/clone/gh_cloner"
require "dev/cd/hook_installer"

module Dev
  module Clone
    # Dispatch for `dev clone …` — clone a GitHub repo via the user's gh auth
    # into the canonical checkout layout under the search root ($DEV_CD_ROOT,
    # default ~/src): `github.com/<org>/<repo>`. Clone only — no `dev up`:
    # provisioning stays a deliberate second step, where credential prompts
    # are expected.
    #
    # The human command is `dev clone [<org>/]<repo>` (org defaults to
    # d3mlabs), handled by the installed shell wrapper (the same one that
    # powers `dev cd`); the wrapper calls the hidden plumbing mode:
    #
    # - `--path [<org>/]<repo>`: clone, then print exactly the destination's
    #   absolute path on stdout (the wrapper `builtin cd`s into it)
    #
    # A bare `dev clone …` reaching this process means the wrapper isn't
    # active in the calling shell. Unlike `dev cd`, the clone still happens —
    # it is the useful work, and on a fresh machine `dev clone` runs before
    # any hook exists — then the hook self-heals and the destination is
    # explained instead of landed in.
    class Accessor
      extend T::Sig

      # `dev clone` was invoked with the wrong arguments.
      class UsageError < RuntimeError; end

      # The canonical destination already exists on disk.
      class DestinationExistsError < RuntimeError; end

      # @param root [String, Pathname] checkout root (default: $DEV_CD_ROOT, else ~/src)
      # @param cloner [Dev::Clone::GhCloner]
      # @param hook_installer [Dev::Cd::HookInstaller]
      sig do
        params(
          root: T.any(String, Pathname),
          cloner: GhCloner,
          hook_installer: Dev::Cd::HookInstaller,
        ).void
      end
      def initialize(root: ENV["DEV_CD_ROOT"] || (Pathname(Dir.home) / "src"),
                     cloner: GhCloner.new, hook_installer: Dev::Cd::HookInstaller.new)
        @root = T.let(Pathname(root).expand_path, Pathname)
        @cloner = cloner
        @hook_installer = hook_installer
      end

      # Dispatch a `dev clone …` invocation.
      #
      # @param args [Array<String>] argv after the "clone" command
      # @param out [IO, StringIO] stdout (the machine-readable payload only)
      # @param err [IO, StringIO] stderr (progress, diagnostics and hints)
      # @return [void]
      # @raise [UsageError] unless exactly one clone target is given
      # @raise [RepoSpec::MalformedRepoError] when the target isn't "<repo>" or "<org>/<repo>"
      # @raise [DestinationExistsError] when the canonical path already exists
      # @raise [GhCloner::CloneFailedError] when the clone itself fails
      sig do
        params(
          args: T::Array[String],
          out: T.any(IO, StringIO),
          err: T.any(IO, StringIO),
        ).void
      end
      def run(args, out: $stdout, err: $stderr)
        plumbing = args.first == "--path"
        query = plumbing ? args.drop(1) : args
        raise UsageError, "usage: dev clone [<org>/]<repo>" unless query.size == 1

        spec = RepoSpec.parse(query.fetch(0))
        destination = @root / spec.relative_path
        if destination.exist?
          raise DestinationExistsError, "#{destination} already exists — jump there with `dev cd #{spec.name}`"
        end

        @cloner.clone(spec.full_name, destination)
        plumbing ? out.puts(destination) : announce(spec, destination, err:)
      end

      private

      # Report a hook-less clone: where it landed, and how to get the landing
      # behavior next time. Also self-heals the hook — a fresh machine's first
      # `dev clone` runs before any `dev up` had a chance to install it.
      #
      # @param spec [Dev::Clone::RepoSpec]
      # @param destination [Pathname]
      # @param err [IO, StringIO]
      # @return [void]
      sig { params(spec: RepoSpec, destination: Pathname, err: T.any(IO, StringIO)).void }
      def announce(spec, destination, err:)
        err.puts "dev: cloned #{spec.full_name} to #{destination}"
        case @hook_installer.ensure_installed
        when :added
          err.puts "dev: shell hook installed — open a new shell and `dev clone` will land you in the checkout. " \
                   "For now: cd #{destination}"
        when :already_present
          err.puts "dev: the dev shell hook is installed but not active in this shell — open a new shell " \
                   "(or source your shell RC). For now: cd #{destination}"
        else
          err.puts "dev: your shell is unsupported for hooks (supported: zsh, bash, fish). " \
                   "Jump there with: cd #{destination}"
        end
      end
    end
  end
end
