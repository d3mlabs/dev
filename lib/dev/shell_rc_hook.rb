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
  class ShellRcHook
    SUPPORTED_SHELLS = %i[zsh bash fish].freeze

    # @param shell [String] the user's login shell (default: $SHELL)
    # @param home [String, Pathname] the user's home directory (default: $HOME)
    def initialize(shell: ENV["SHELL"] || "/bin/sh", home: ENV["HOME"] || Dir.home)
      @shell = shell
      @home = Pathname(home)
    end

    # The supported shell this user runs, or nil for unsupported shells.
    #
    # @return [Symbol, nil] :zsh, :bash, :fish, or nil
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
    # @return [Symbol, false] :added, :already_present, or false when the
    #   shell is unsupported or has no snippet
    def ensure_snippet(marker:, snippets:, present_markers: [])
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
    def bash_rc_file
      profile = @home / ".bash_profile"
      bashrc = @home / ".bashrc"
      (!profile.exist? && bashrc.exist?) ? bashrc : profile
    end
  end
end
