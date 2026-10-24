# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/shadowenv_file"
require "dev/shell_rc_hook"

module Dev
  # The language-specific half of a locked Ruby's activation in the project
  # shadowenv: .shadowenv.d/510_ruby.lisp (RUBY_ROOT, GEM_ROOT, GEM_HOME
  # and their PATH entries), `.ruby-version`, the trust, the shell hook.
  #
  # Nothing here installs a Ruby. The interpreter is a `ruby` pin in
  # dependencies.rb — an immutable `ruby@X.Y.Z` bottle from the d3mlabs tap
  # that brew installs like any formula — and the brew integration calls
  # activate! once the keg is installed and its bin is on the project PATH.
  module ShadowenvRuby
    extend T::Sig
    include Kernel

    LISP_FILENAME = "510_ruby.lisp"

    module_function

    # Activate one installed Ruby in the project shadowenv: the lisp points
    # RUBY_ROOT/GEM_HOME at the keg (placed for this side of the build
    # container by ShadowenvFile), `.ruby-version` carries the version, the
    # directory is trusted and the shell hook ensured.
    #
    # @param keg [Pathname] the installed Ruby's prefix (brew's keg)
    # @param version [String] the version the lock pins
    # @param project_root [Pathname]
    # @return [void]
    sig { params(keg: Pathname, version: String, project_root: Pathname).void }
    def activate!(keg:, version:, project_root:)
      ShadowenvFile.write!(project_root:, filename: LISP_FILENAME, body: generate_ruby_lisp(keg.to_s, version))
      File.write(project_root / ".ruby-version", "#{version}\n")
      ensure_shadowenv_shell_hook!
    end

    # --- internal helpers ------------------------------------------------

    sig { params(ruby_version: String).returns(String) }
    def gem_api_version(ruby_version)
      parts = ruby_version.split(".").map(&:to_i)
      return "#{parts[0]}.#{parts[1]}.0" if parts.size >= 2
      "#{ruby_version}.0"
    end

    # The shadowenv lisp that activates one Ruby: clears any prior ruby/gem paths,
    # then exports RUBY_ROOT/GEM_ROOT and a HOME-derived GEM_HOME
    # (`~/.gem/<engine>/<version>`).
    #
    # @param ruby_root [String] the installed Ruby's prefix
    # @param ruby_version [String] the version it provides
    # @return [String] the lisp source
    sig { params(ruby_root: String, ruby_version: String).returns(String) }
    def generate_ruby_lisp(ruby_root, ruby_version)
      gem_root = File.join(ruby_root, "lib", "ruby", "gems", gem_api_version(ruby_version))
      gem_root = File.join(ruby_root, "lib", "ruby", ruby_version) unless File.directory?(gem_root)
      <<~LISP
        (provide "ruby" "#{ruby_version}")

        (when-let ((ruby-root (env/get "RUBY_ROOT")))
         (env/remove-from-pathlist "PATH" (path-concat ruby-root "bin"))
         (when-let ((gem-root (env/get "GEM_ROOT")))
           (env/remove-from-pathlist "PATH" (path-concat gem-root "bin")))
         (when-let ((gem-home (env/get "GEM_HOME")))
           (env/remove-from-pathlist "PATH" (path-concat gem-home "bin"))
           (env/remove-from-pathlist "GEM_PATH" gem-home)))

        (env/set "GEM_PATH" ())
        (env/set "GEM_HOME" ())
        (env/set "RUBYOPT" ())

        (env/set "RUBY_ROOT" "#{ruby_root}")
        (env/prepend-to-pathlist "PATH" "#{File.join(ruby_root, "bin")}")
        (env/set "RUBY_ENGINE" "ruby")
        (env/set "RUBY_VERSION" "#{ruby_version}")
        (env/set "GEM_ROOT" "#{gem_root}")

        (when-let ((gem-root (env/get "GEM_ROOT")))
          (env/prepend-to-pathlist "GEM_PATH" gem-root)
          (env/prepend-to-pathlist "PATH" (path-concat gem-root "bin")))

        (let ((gem-home
              (path-concat (env/get "HOME") ".gem" (env/get "RUBY_ENGINE") (env/get "RUBY_VERSION"))))
          (do
            (env/set "GEM_HOME" gem-home)
            (env/prepend-to-pathlist "GEM_PATH" gem-home)
            (env/prepend-to-pathlist "PATH" (path-concat gem-home "bin"))))
      LISP
    end

    # Ensure the shadowenv activation hook is in the user's shell RC.
    #
    # Delegates the shell → RC-file mapping and the idempotent append to the
    # shared Dev::ShellRcHook installer; this module only declares its snippet
    # per shell. "shadowenv init" counts as already installed so hand-added
    # hook lines (pre-dating the marker) are never duplicated.
    #
    # @return [Symbol, false] :added, :already_present, or false (unsupported shell)
    sig { returns(T.any(Symbol, FalseClass)) }
    def ensure_shadowenv_shell_hook!
      Dev::ShellRcHook.new.ensure_snippet(
        marker: "# Shadowenv (added by dev)",
        present_markers: ["shadowenv init"],
        snippets: {
          zsh: <<~SNIPPET.chomp,
            eval "$(shadowenv init zsh)"
            # Optional: show active shadowenv in prompt: setopt PROMPT_SUBST && PROMPT='$(shadowenv prompt-widget)'"$PROMPT"
          SNIPPET
          bash: <<~SNIPPET.chomp,
            eval "$(shadowenv init bash)"
            # Optional: show active shadowenv in prompt: PS1='$(shadowenv prompt-widget)'"$PS1"
          SNIPPET
          fish: <<~SNIPPET.chomp,
            shadowenv init fish | source
            # Optional: see https://shopify.github.io/shadowenv/best-practices/#prompt-widget for fish
          SNIPPET
        },
      )
    rescue => e
      $stderr.puts "dev: Could not add shadowenv hook to shell profile: #{e.message}"
      false
    end
  end
end
