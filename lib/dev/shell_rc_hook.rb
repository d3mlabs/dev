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

    # The user's shell is none of the supported ones (or the snippet set
    # declares nothing for it): there is no RC file to install into.
    class UnsupportedShellError < RuntimeError; end

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

    # Ensure the snippet for the user's shell is in their RC file.
    #
    # Idempotent: the marker line is written above the snippet, and when
    # the RC already contains it (or any of the extra present_markers, e.g.
    # a hand-installed hook line) nothing is appended. Success is returning;
    # whether this call did the appending is not the caller's business —
    # #snippet_present? answers whether the RC carries the snippet.
    #
    # Off a tty nothing is written and nothing is raised: the one case a
    # returning ensure leaves the RC without the snippet.
    #
    # @param marker [String] comment line identifying the snippet (e.g. "# dev cd (added by dev)")
    # @param snippets [Hash{Symbol => String}] per-shell snippet bodies, keyed :zsh / :bash / :fish
    # @param present_markers [Array<String>] extra strings whose presence counts as installed
    # @return [void]
    # @raise [UnsupportedShellError] when the shell is unsupported or the
    #   snippet set has nothing for it
    sig do
      params(
        marker: String,
        snippets: T::Hash[Symbol, String],
        present_markers: T::Array[String],
      ).void
    end
    def ensure_snippet(marker:, snippets:, present_markers: [])
      return unless @interactive

      kind = supported_shell_kind
      snippet = snippets.fetch(kind) do
        raise UnsupportedShellError, "no snippet for #{@shell} (supported: #{snippets.keys.join(", ")})"
      end

      rc = rc_file(kind)
      return if rc.exist? && markers_present?(rc.read, marker, present_markers)

      rc.dirname.mkpath
      rc.open("a") do |f|
        f.puts("\n#{marker}")
        f.puts(snippet)
      end
    end

    # Whether the user's RC file already carries the snippet (by its marker
    # or any of the present_markers).
    #
    # @param marker [String] comment line identifying the snippet
    # @param present_markers [Array<String>] extra strings whose presence counts as installed
    # @return [Boolean]
    # @raise [UnsupportedShellError] when the shell is unsupported (no RC file to read)
    sig { params(marker: String, present_markers: T::Array[String]).returns(T::Boolean) }
    def snippet_present?(marker:, present_markers: [])
      rc = rc_file(supported_shell_kind)
      rc.exist? && markers_present?(rc.read, marker, present_markers)
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

    # The user's shell kind, which must be a supported one to have an RC
    # file at all.
    #
    # @return [Symbol] :zsh, :bash, or :fish
    # @raise [UnsupportedShellError] for any other shell
    sig { returns(Symbol) }
    def supported_shell_kind
      shell_kind || raise(UnsupportedShellError, "#{@shell} is not a supported shell (supported: #{SUPPORTED_SHELLS.join(", ")})")
    end

    # @param content [String] the RC file's content
    # @param marker [String]
    # @param present_markers [Array<String>]
    # @return [Boolean] whether any marker is in the content
    sig { params(content: String, marker: String, present_markers: T::Array[String]).returns(T::Boolean) }
    def markers_present?(content, marker, present_markers)
      [marker, *present_markers].any? { |candidate| content.include?(candidate) }
    end

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
