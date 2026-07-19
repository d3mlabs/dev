# frozen_string_literal: true

require "fileutils"
require "dev/shell_rc_hook"

# Shadowenv Ruby provisioning: installs Ruby via rbenv, generates
# .shadowenv.d/510_ruby.lisp, trusts, and ensures the shell hook.
# Used by the dev CLI core as a pre-dispatch step for every command.
module ShadowenvRuby
  MIN_RUBY = Gem::Requirement.new(">= 2.7.0")
  LISP_FILENAME = "510_ruby.lisp"

  # Stdlib C-extensions every dev workflow depends on. rbenv/ruby-build silently
  # *skips* an extension when its dev library is missing at compile time, so a Ruby
  # can install "successfully" yet blow up on the first `require` deep inside bundler
  # ("cannot load such file -- zlib"). We make that failure mode impossible: provision
  # the libraries below before building, and hard-verify these after.
  REQUIRED_EXTENSIONS = %w[zlib openssl psych].freeze

  # Homebrew formulae that supply the headers/libs ruby-build links the required
  # extensions against, mapped to the `--with-<flag>-dir` configure flag that points
  # Ruby's build at the brew copy. Works on macOS and Linuxbrew alike (the box).
  RUBY_BUILD_BREW_DEPS = {
    "openssl@3" => "openssl",
    "readline" => "readline",
    "libyaml" => "libyaml",
    "zlib" => "zlib",
  }.freeze

  module_function

  # Resolve the Ruby version to provision. Explicit pin wins; falls back to
  # the Homebrew Ruby version; aborts if neither is available or too old.
  def resolve_ruby_version(explicit_version)
    version = explicit_version || detect_homebrew_ruby_version
    unless version
      Kernel.abort("dev: No Ruby version specified in dev.yml and Homebrew Ruby not found. Run: brew install ruby")
      return
    end
    unless MIN_RUBY.satisfied_by?(Gem::Version.new(version))
      Kernel.abort("dev: Resolved Ruby #{version} is below dev's minimum (#{MIN_RUBY}). Pin a newer version in dev.yml or run: brew upgrade ruby")
      return
    end
    version
  end

  # Returns the version string of the Homebrew-installed Ruby, or nil.
  def detect_homebrew_ruby_version
    prefix = brew_prefix_for("ruby")
    return nil unless prefix
    # /opt/homebrew/Cellar/ruby/4.0.1 -> "4.0.1"
    realpath = File.realpath(prefix) rescue prefix
    version = File.basename(realpath)
    return version if version.match?(/\A\d+\.\d+/)
    # Fallback: ask the Homebrew ruby binary directly
    ruby_bin = File.join(prefix, "bin", "ruby")
    return nil unless File.executable?(ruby_bin)
    out = IO.popen([ruby_bin, "-e", "puts RUBY_VERSION"], err: File::NULL, &:read)
    v = out&.strip
    (v && !v.empty?) ? v : nil
  end

  # Returns true when .shadowenv.d/510_ruby.lisp exists and already
  # provisions the requested version. This is the fast-path check.
  def provisioned?(ruby_version, project_root:)
    lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
    return false unless File.exist?(lisp_path)
    content = File.read(lisp_path)
    content.include?(%(provide "ruby" "#{ruby_version}"))
  end

  # Full provisioning: install Ruby via rbenv if needed (with the build deps that
  # guarantee the required extensions compile), verify it is not crippled, write the
  # lisp, trust shadowenv, ensure shell hook. Idempotent.
  def setup!(ruby_version:, project_root:)
    root = project_root.to_s
    ruby_root = ensure_ruby_installed!(ruby_version)
    return false unless ruby_root

    shadowenv_d = File.join(root, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    lisp_path = File.join(shadowenv_d, LISP_FILENAME)
    File.write(lisp_path, generate_ruby_lisp(ruby_root, ruby_version))

    ruby_version_path = File.join(root, ".ruby-version")
    File.write(ruby_version_path, "#{ruby_version}\n")

    Dir.chdir(root) do
      system("shadowenv", "trust", out: File::NULL, err: File::NULL)
    end

    ensure_shadowenv_shell_hook!
    true
  end

  # --- internal helpers ------------------------------------------------

  def find_ruby_root(version)
    rbenv_root = ENV["RBENV_ROOT"] || File.join(ENV["HOME"] || Dir.home, ".rbenv")
    rbenv_path = File.join(rbenv_root, "versions", version)
    return File.expand_path(rbenv_path) if File.directory?(rbenv_path)
    nil
  end

  def brew_prefix_for(formula)
    return nil unless system("command -v brew >/dev/null 2>&1")
    out = IO.popen(["brew", "--prefix", formula], err: File::NULL, &:read)
    prefix = out&.strip
    (prefix && !prefix.empty? && File.directory?(prefix)) ? prefix : nil
  end

  def path_with_brew_bin
    prefix = ENV["HOMEBREW_PREFIX"]
    prefix ||= begin
      out = IO.popen(["brew", "prefix"], err: File::NULL, &:read)
      out&.strip
    end
    return ENV["PATH"] unless prefix && File.directory?(prefix)
    "#{File.join(prefix, "bin")}:#{ENV["PATH"]}"
  end

  # Resolve a usable Ruby for the version: install it if absent, repair it if a
  # pre-existing install is crippled (missing a required extension), and abort with
  # actionable steps if it still can't be made whole. The repair path matters on a
  # long-lived box where a Ruby was first built before its dev libs were present.
  def ensure_ruby_installed!(version)
    ruby_root = find_ruby_root(version)

    if ruby_root && extensions_ok?(ruby_root)
      return ruby_root
    elsif ruby_root
      missing = missing_extensions(ruby_root)
      $stderr.puts "dev: Ruby #{version} is missing required extension(s): #{missing.join(', ')}. Rebuilding with the right deps..."
      install_ruby_with_version_manager(version, force: true)
    else
      install_ruby_with_version_manager(version)
    end

    ruby_root = find_ruby_root(version)
    unless ruby_root
      $stderr.puts "dev: Ruby #{version} not found. Install: brew install rbenv ruby-build && rbenv install #{version}"
      return nil
    end

    verify_extensions!(ruby_root, version)
    ruby_root
  end

  # Install (or force-reinstall) the Ruby via rbenv, first ensuring the build-time
  # libraries are present and pointing ruby-build at them, so the required extensions
  # are compiled rather than silently skipped.
  def install_ruby_with_version_manager(version, force: false)
    env = { "PATH" => path_with_brew_bin }
    return false unless system(env, "which", "rbenv", out: File::NULL, err: File::NULL)

    ensure_ruby_build_deps!(env)
    system(env, "rbenv", "uninstall", "--force", version, out: File::NULL, err: File::NULL) if force
    $stderr.puts "dev: Installing Ruby #{version} with rbenv (one-time)..."
    system(ruby_build_env(env), "rbenv", "install", "--skip-existing", version)
  end

  # Abort (loudly, with a fix) if the provisioned Ruby is missing a required
  # extension. A crippled Ruby must never pass silently to surface as a cryptic
  # bundler error later.
  def verify_extensions!(ruby_root, version)
    missing = missing_extensions(ruby_root)
    return if missing.empty?

    Kernel.abort(<<~MSG)
      dev: Ruby #{version} is built without required extension(s): #{missing.join(', ')}.
      ruby-build skips an extension when its dev library is missing at build time.
      Install the libraries and reinstall:
        brew install #{RUBY_BUILD_BREW_DEPS.keys.join(' ')}     # or apt: zlib1g-dev libssl-dev libyaml-dev libreadline-dev
        rbenv uninstall -f #{version} && rbenv install #{version}
    MSG
  end

  # The subset of REQUIRED_EXTENSIONS the given Ruby cannot `require`. A Ruby whose
  # binary is missing entirely counts as missing all of them.
  def missing_extensions(ruby_root)
    ruby_bin = File.join(ruby_root, "bin", "ruby")
    return REQUIRED_EXTENSIONS.dup unless File.executable?(ruby_bin)

    REQUIRED_EXTENSIONS.reject do |ext|
      system(ruby_bin, "-e", "require #{ext.inspect}", out: File::NULL, err: File::NULL)
    end
  end

  def extensions_ok?(ruby_root)
    missing_extensions(ruby_root).empty?
  end

  # Best-effort install of the build-time libraries via Homebrew. A no-op when brew
  # is absent (e.g. an apt-only host) — verify_extensions! still guards the result.
  def ensure_ruby_build_deps!(env)
    return unless system(env, "command -v brew >/dev/null 2>&1")

    RUBY_BUILD_BREW_DEPS.each_key do |formula|
      next if system(env, "brew", "list", "--versions", formula, out: File::NULL, err: File::NULL)
      system(env, "brew", "install", formula)
    end
  end

  # Augment the install env so ruby-build links the brew-provided libraries. Adds a
  # `--with-<lib>-dir` for each available formula plus the brew prefix's include/lib/
  # pkgconfig, which is the documented fix for ruby-build on Linuxbrew. Returns the
  # env unchanged when brew isn't present.
  def ruby_build_env(env)
    prefix = homebrew_prefix
    return env unless prefix

    configure_opts = RUBY_BUILD_BREW_DEPS.filter_map do |formula, flag|
      dir = brew_prefix_for(formula)
      "--with-#{flag}-dir=#{dir}" if dir
    end

    # -rpath alongside -L: on Linuxbrew, ruby-build links miniruby against brew's
    # libs (e.g. libcrypt.so.2 from libxcrypt) but bakes no runtime search path, so
    # the just-built miniruby dies with "libcrypt.so.2: cannot open shared object"
    # mid-build. Baking the brew lib dir into the rpath makes the built ruby find
    # its brew libs at runtime. Harmless on macOS (rpath to an already-found dir).
    lib = File.join(prefix, "lib")

    env.merge(
      "RUBY_CONFIGURE_OPTS" => [env["RUBY_CONFIGURE_OPTS"], *configure_opts].compact.reject(&:empty?).join(" "),
      "PKG_CONFIG_PATH" => [File.join(prefix, "lib", "pkgconfig"), ENV["PKG_CONFIG_PATH"]].compact.reject(&:empty?).join(":"),
      "CPPFLAGS" => [ENV["CPPFLAGS"], "-I#{File.join(prefix, "include")}"].compact.reject(&:empty?).join(" "),
      "LDFLAGS" => [ENV["LDFLAGS"], "-L#{lib}", "-Wl,-rpath,#{lib}"].compact.reject(&:empty?).join(" "),
    )
  end

  # The Homebrew prefix (HOMEBREW_PREFIX, else `brew --prefix`), or nil when brew is
  # unavailable.
  def homebrew_prefix
    prefix = ENV["HOMEBREW_PREFIX"]
    prefix ||= begin
      out = IO.popen(["brew", "--prefix"], err: File::NULL, &:read)
      out&.strip
    rescue Errno::ENOENT
      nil
    end
    (prefix && !prefix.empty? && File.directory?(prefix)) ? prefix : nil
  end

  def gem_api_version(ruby_version)
    parts = ruby_version.split(".").map(&:to_i)
    return "#{parts[0]}.#{parts[1]}.0" if parts.size >= 2
    "#{ruby_version}.0"
  end

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
