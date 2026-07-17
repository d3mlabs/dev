# frozen_string_literal: true

require "fileutils"

module Dev
  module Cd
    # Installs the `dev` shell function (and completion) that turns `dev cd`
    # into a real directory change in the current shell. Mirrors shadowenv's
    # supported shells: zsh, bash, and fish. Idempotent — re-running does not
    # duplicate RC lines.
    class ShellHook
      MARKER = "# Dev cd (added by dev)"

      # Ensure the hook exists in the current shell's RC file.
      #
      # @param env [Hash] environment (injectable for tests)
      # @return [Symbol] `:added`, `:already_present`, or `false` when unsupported
      def self.ensure!(env: ENV)
        new(env:).ensure!
      end

      # @param env [Hash]
      def initialize(env: ENV)
        @env = env
      end

      # @return [Symbol, false]
      def ensure!
        shell = @env["SHELL"] || "/bin/sh"
        home = @env["HOME"] || Dir.home
        profile_path, snippet = profile_and_snippet(shell, home)
        return false unless profile_path && snippet

        if File.exist?(profile_path)
          content = File.read(profile_path)
          return :already_present if content.include?(MARKER)
        end

        FileUtils.mkdir_p(File.dirname(profile_path))
        File.open(profile_path, "a") do |f|
          f.puts "\n#{MARKER}"
          f.puts snippet
        end
        :added
      rescue StandardError => e
        warn "dev: Could not add dev cd hook to shell profile: #{e.message}"
        false
      end

      private

      # @param shell [String]
      # @param home [String]
      # @return [Array(String, String), Array(nil, nil)]
      def profile_and_snippet(shell, home)
        if shell.include?("zsh")
          [File.join(home, ".zshrc"), zsh_snippet]
        elsif shell.include?("bash")
          profile_path = File.join(home, ".bash_profile")
          unless File.exist?(profile_path)
            bashrc = File.join(home, ".bashrc")
            profile_path = bashrc if File.exist?(bashrc)
          end
          [profile_path, bash_snippet]
        elsif shell.include?("fish")
          fish_config_dir = File.join(home, ".config", "fish")
          FileUtils.mkdir_p(fish_config_dir)
          [File.join(fish_config_dir, "config.fish"), fish_snippet]
        else
          [nil, nil]
        end
      end

      # @return [String]
      def zsh_snippet
        <<~'ZSH'
          dev() {
            if [[ "$1" == "cd" ]]; then
              shift
              local resolved
              resolved="$(command dev cd --resolve "$@")" || return $?
              builtin cd "$resolved"
            else
              command dev "$@"
            fi
          }
          _dev() {
            if (( CURRENT >= 3 )) && [[ "$words[2]" == "cd" ]]; then
              local -a candidates
              candidates=("${(@f)$(command dev cd --complete "${words[CURRENT]}")}")
              compadd -a candidates
            fi
          }
          if (( $+functions[compdef] )); then
            compdef _dev dev
          fi
        ZSH
      end

      # @return [String]
      def bash_snippet
        <<~'BASH'
          dev() {
            if [[ "$1" == "cd" ]]; then
              shift
              local resolved
              resolved="$(command dev cd --resolve "$@")" || return $?
              builtin cd "$resolved"
            else
              command dev "$@"
            fi
          }
          _dev() {
            local cur="${COMP_WORDS[COMP_CWORD]}"
            if [[ "${COMP_WORDS[1]}" == "cd" ]]; then
              local candidates
              candidates="$(command dev cd --complete "${cur}")"
              COMPREPLY=($(compgen -W "${candidates}" -- "${cur}"))
            fi
          }
          if type complete >/dev/null 2>&1; then
            complete -F _dev dev
          fi
        BASH
      end

      # @return [String]
      def fish_snippet
        <<~'FISH'
          function dev
            if test (count $argv) -gt 0; and test $argv[1] = cd
              set -e argv[1]
              set -l resolved (command dev cd --resolve $argv); or return $status
              cd $resolved
            else
              command dev $argv
            end
          end

          complete -c dev -n 'not __fish_seen_subcommand_from cd' -a cd -d 'Change to a local checkout'
          complete -c dev -n '__fish_seen_subcommand_from cd' -a '(command dev cd --complete (commandline -ct))' -f
        FISH
      end
    end
  end
end
