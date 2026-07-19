# frozen_string_literal: true

require "dev/shell_rc_hook"

module Dev
  module Cd
    # Installs the `dev cd` shell hook through the shared RC-hook installer.
    #
    # The hook is a `dev()` wrapper function (a Ruby child cannot change the
    # parent shell's cwd): it intercepts `dev cd …`, resolves the target via
    # the hidden `--resolve` plumbing, and `builtin cd`s into it in the
    # current shell — so chpwd hooks (e.g. shadowenv) fire exactly as they
    # would for a manual `cd`. Everything else falls through to `command dev`.
    #
    # Each snippet also registers Tab completion backed by `--candidates`.
    # Completion replaces the typed token with the rendered candidate (fuzzy
    # completion is token replacement, not literal prefix extension):
    # zsh uses `compadd -U` with menu-select scoped to `dev` only (guarded on
    # compsys being initialized), bash sets COMPREPLY directly, and fish
    # registers a `complete -c dev` source (fish applies its own filtering,
    # so fuzzy tokens may complete only literally there).
    class HookInstaller
      MARKER = "# dev cd (added by dev)"

      ZSH_SNIPPET = <<~'SNIPPET'
        dev() {
          if [[ "$1" == cd ]]; then
            shift
            local __dev_cd_target
            __dev_cd_target="$(command dev cd --resolve "$@")" || return $?
            builtin cd -- "$__dev_cd_target"
          else
            command dev "$@"
          fi
        }
        if (( $+functions[compdef] )) || whence compdef >/dev/null 2>&1; then
          _dev() {
            if [[ "${words[2]}" == cd && $CURRENT -eq 3 ]]; then
              local -a __dev_cd_candidates
              __dev_cd_candidates=(${(f)"$(command dev cd --candidates "${words[CURRENT]}" 2>/dev/null)"})
              (( ${#__dev_cd_candidates} )) && compadd -U -- "${__dev_cd_candidates[@]}"
            fi
          }
          compdef _dev dev
          zstyle ':completion:*:*:dev:*' menu select
        fi
      SNIPPET

      BASH_SNIPPET = <<~'SNIPPET'
        dev() {
          if [ "$1" = cd ]; then
            shift
            local __dev_cd_target
            __dev_cd_target="$(command dev cd --resolve "$@")" || return $?
            builtin cd -- "$__dev_cd_target"
          else
            command dev "$@"
          fi
        }
        _dev_cd_completion() {
          COMPREPLY=()
          if [ "${COMP_WORDS[1]}" = cd ] && [ "$COMP_CWORD" -eq 2 ]; then
            local IFS=$'\n'
            COMPREPLY=($(command dev cd --candidates "${COMP_WORDS[2]}" 2>/dev/null))
          fi
        }
        complete -F _dev_cd_completion dev
      SNIPPET

      FISH_SNIPPET = <<~'SNIPPET'
        function dev
            if test (count $argv) -ge 1; and test "$argv[1]" = cd
                set -e argv[1]
                set -l __dev_cd_target (command dev cd --resolve $argv)
                or return $status
                builtin cd $__dev_cd_target
            else
                command dev $argv
            end
        end
        complete -c dev -n '__fish_seen_subcommand_from cd' -f -a '(command dev cd --candidates (commandline -ct) 2>/dev/null)'
      SNIPPET

      # @param rc_hook [Dev::ShellRcHook] the shared RC-snippet installer
      def initialize(rc_hook: ShellRcHook.new)
        @rc_hook = rc_hook
      end

      # Ensure the wrapper function + completer are in the user's shell RC.
      #
      # @return [Symbol, false] :added, :already_present, or false (unsupported shell)
      def ensure_installed
        @rc_hook.ensure_snippet(
          marker: MARKER,
          snippets: { zsh: ZSH_SNIPPET.chomp, bash: BASH_SNIPPET.chomp, fish: FISH_SNIPPET.chomp },
        )
      end
    end
  end
end
