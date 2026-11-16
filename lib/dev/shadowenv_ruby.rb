# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/container_context"
require "dev/data_root"
require "dev/deps/artifact_store"
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
  # Nothing here installs a gem either: the lisp names the gem home, and
  # `gem install bundler` / `bundle install` (BundlerIntegration,
  # EnsureBundler) land there because they run through the shadowenv.
  #
  # The gem home is the project's, in the store: a workdir keyed by
  # project, side of the build container and keg
  # (`~/.dev/gems/<project>/<side>/<keg version>`), converged in place by
  # bundler toward the lock. In the store, and the user's, because the keg's
  # own gem dir is the brew prefix owner's — on a shared machine every other
  # user can read it and write nothing, so `bundle install` fails for anyone
  # but the owner — and because one gem home per project is what lets
  # `bundle clean` in one project touch nothing of another's. Per side
  # because a native extension is built for one OS/arch and a Linux host
  # bind-mounts its data root into the container at the same path. Per keg,
  # by brew's full version, because a native extension links the libruby
  # that built it: a rebuilt keg is a new gem home. A workdir, not a tree:
  # a gem home has no built-once layer the way a venv's interpreter does —
  # bundler converges the whole directory every run, so presence proves
  # nothing. `gem_home_key` is the one place the store path is decided.
  module ShadowenvRuby
    extend T::Sig
    include Kernel

    LISP_FILENAME = "510_ruby.lisp"
    # The store base every project's gem homes live under; the store
    # re-roots the `~/.dev` prefix onto the data root (Dev::DataRoot).
    GEM_HOMES_ROOT = T.let("#{Dev::DataRoot::HOME_ROOT}/gems".freeze, String)

    module_function

    # The store key of a project's gem home on one keg, for one side of the
    # build container: `~/.dev/gems/<project>/<side>/<keg version>`. The keg
    # is named by brew's full version, revision included (`4.0.6_1`), so a
    # rebuilt keg is a new gem home. The venv's key (ShadowenvPython.venv_key)
    # has the same shape.
    #
    # @param project_name [String] the project's package identity (dev.yml `name`)
    # @param keg [Pathname] the installed Ruby's prefix (brew's keg)
    # @param inside [Boolean] whether this dev runs inside the build container
    # @return [Deps::TreeKey]
    sig { params(project_name: String, keg: Pathname, inside: T::Boolean).returns(Deps::TreeKey) }
    def gem_home_key(project_name:, keg:, inside: ContainerContext.inside?)
      Deps::TreeKey.new(
        base: "#{GEM_HOMES_ROOT}/#{project_name}",
        platform: ContainerContext.side(inside:),
        version: keg.basename.to_s,
      )
    end

    # Activate one installed Ruby in the project shadowenv: this side's gem
    # home exists in the store, the lisp points RUBY_ROOT at the keg and
    # GEM_HOME at the gem home (placed for this side of the build container
    # by ShadowenvFile), `.ruby-version` carries the version, the directory
    # is trusted and the shell hook ensured.
    #
    # @param keg [Pathname] the installed Ruby's prefix (brew's keg)
    # @param version [String] the version the lock pins
    # @param project_root [Pathname]
    # @param project_name [String] the project's package identity (dev.yml `name`)
    # @param store [Deps::ArtifactStore] where the gem home lives
    # @return [void]
    sig do
      params(
        keg: Pathname,
        version: String,
        project_root: Pathname,
        project_name: String,
        store: Deps::ArtifactStore,
      ).void
    end
    def activate!(keg:, version:, project_root:, project_name:, store:)
      gem_home = store.workdir(gem_home_key(project_name:, keg:))
      ShadowenvFile.write!(project_root:, filename: LISP_FILENAME, body: generate_ruby_lisp(keg.to_s, version, gem_home.to_s))
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

    # The shadowenv lisp that activates one Ruby: clears any prior ruby/gem
    # paths, then exports RUBY_ROOT, the keg's own gem dir as GEM_ROOT and
    # the project's gem home as GEM_HOME.
    #
    # GEM_PATH is the gem home followed by the keg's gem dir, so the keg's
    # default gems — bundler's own `bundled_gems`, json, psych — stay
    # loadable without being copied into the gem home; PATH gets the gem
    # home's bin ahead of the keg's, so a bundler the project installed wins
    # over the keg's. Nothing derives from HOME: a `~/.gem/<engine>/<version>`
    # keyed by version alone would be shared by two builds of one version
    # (a keg beside an earlier rbenv install) whose extensions are linked to
    # different librubies.
    #
    # @param ruby_root [String] the installed Ruby's prefix
    # @param ruby_version [String] the version it provides
    # @param gem_home [String] the project's gem home in the store
    # @return [String] the lisp source
    sig { params(ruby_root: String, ruby_version: String, gem_home: String).returns(String) }
    def generate_ruby_lisp(ruby_root, ruby_version, gem_home)
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
        (env/set "GEM_HOME" "#{gem_home}")
        (env/prepend-to-pathlist "GEM_PATH" "#{gem_root}")
        (env/prepend-to-pathlist "GEM_PATH" "#{gem_home}")
        (env/prepend-to-pathlist "PATH" "#{File.join(gem_root, "bin")}")
        (env/prepend-to-pathlist "PATH" "#{File.join(gem_home, "bin")}")
      LISP
    end

    # Ensure the shadowenv activation hook is in the user's shell RC.
    #
    # Delegates the shell → RC-file mapping and the idempotent append to the
    # shared Dev::ShellRcHook installer; this module only declares its snippet
    # per shell. "shadowenv init" counts as already installed so hand-added
    # hook lines (pre-dating the marker) are never duplicated. Off a tty
    # nothing is written (ShellRcHook — an agent run has no shell to hook).
    # Warn-only: an unsupported shell or an unwritable RC must not fail the
    # Ruby activation it rides on.
    #
    # @param interactive [Boolean] whether a human is at a terminal
    #   (default: stdin is a tty)
    # @return [void]
    sig { params(interactive: T::Boolean).void }
    def ensure_shadowenv_shell_hook!(interactive: $stdin.tty?)
      Dev::ShellRcHook.new(interactive: interactive).ensure_snippet(
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
    end
  end
end
