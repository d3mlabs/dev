# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  # Idempotent installer of snippets into the user's shell RC file.
  #
  # Owns the generic mechanism every dev shell hook shares: shell detection
  # from $SHELL, RC-file resolution per shell (`.zshrc`, `.bash_profile`
  # falling back to `.bashrc`, fish's `config.fish`), and the marker-guarded
  # append that makes re-runs no-ops. Clients (shadowenv activation, the
  # `dev cd` wrapper) declare only their marker and per-shell snippets.
  #
  # Supported shells: zsh, bash, fish — the set every dev RC hook targets.
  #
  # A hook is a convenience for a human's interactive shell, so it is only
  # installed when a human is there: off a tty (a runner job, an agent run
  # as its own user — ai-flow#116, dev#483) the write is a no-op, never a
  # profile scribbled into an identity that has no shell to hook, and never
  # a "Permission denied" for one that cannot. A run uses `shadowenv exec`.
  class ShellRcHook
    extend T::Sig

    SUPPORTED_SHELLS = T.let(%i[zsh bash fish].freeze, T::Array[Symbol])

    # @param shell [String] the user's login shell (default: $SHELL)
    # @param home [String, Pathname] the user's home directory (default: $HOME)
    # @param interactive [Boolean] whether a human is at a terminal
    #   (default: stdin is a tty); false makes every install a no-op
    sig { params(shell: String, home: T.any(String, Pathname), interactive: T::Boolean).void }
    def initialize(shell: ENV["SHELL"] || "/bin/sh", home: ENV["HOME"] || Dir.home, interactive: $stdin.tty?)
      @shell = shell
      @home = T.let(Pathname(home), Pathname)
      @interactive = interactive
    end

    # The supported shell this user runs, or nil for unsupported shells.
    #
    # @return [Symbol, nil] :zsh, :bash, :fish, or nil
    sig { returns(T.nilable(Symbol)) }
    def shell_kind
      SUPPORTED_SHELLS.find { |kind| @shell.include?(kind.to_s) }
    end

    # Append the snippet for the user's shell to their RC file, once.
    #
    # The marker line is written above the snippet and guards idempotence:
    # when the RC already contains the marker (or any of the extra
    # present_markers, e.g. a hand-installed hook line), nothing is appended.
    #
    # @param marker [String] comment line identifying the snippet (e.g. "# dev cd (added by dev)")
    # @param snippets [Hash{Symbol => String}] per-shell snippet bodies, keyed :zsh / :bash / :fish
    # @param present_markers [Array<String>] extra strings whose presence counts as installed
    # @return [Symbol, false] :added, :already_present, :skipped (not
    #   interactive — nothing touched), or false when the shell is
    #   unsupported or has no snippet
    sig do
      params(
        marker: String,
        snippets: T::Hash[Symbol, String],
        present_markers: T::Array[String],
      ).returns(T.any(Symbol, FalseClass))
    end
    def ensure_snippet(marker:, snippets:, present_markers: [])
      return :skipped unless @interactive

      kind = shell_kind
      snippet = kind && snippets[kind]
      return false unless kind && snippet

      rc = rc_file(kind)
      if rc.exist?
        content = rc.read
        return :already_present if ([marker] + present_markers).any? { |m| content.include?(m) }
      end

      rc.dirname.mkpath
      rc.open("a") do |f|
        f.puts("\n#{marker}")
        f.puts(snippet)
      end
      :added
    end

    # The RC file dev hooks install into for a given shell.
    #
    # @param kind [Symbol] :zsh, :bash, or :fish
    # @return [Pathname]
    # @raise [ArgumentError] for an unsupported shell kind
    sig { params(kind: Symbol).returns(Pathname) }
    def rc_file(kind)
      case kind
      when :zsh then @home / ".zshrc"
      when :bash then bash_rc_file
      when :fish then @home / ".config" / "fish" / "config.fish"
      else raise ArgumentError, "unsupported shell: #{kind}"
      end
    end

    private

    # `.bash_profile` by default; an existing `.bashrc` wins only when there
    # is no `.bash_profile` yet (matching the historical shadowenv behavior).
    #
    # @return [Pathname]
    sig { returns(Pathname) }
    def bash_rc_file
      profile = @home / ".bash_profile"
      bashrc = @home / ".bashrc"
      (!profile.exist? && bashrc.exist?) ? bashrc : profile
    end
  end
end
