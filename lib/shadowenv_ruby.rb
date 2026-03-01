# frozen_string_literal: true

require "fileutils"

# Shadowenv Ruby provisioning: installs Ruby via rbenv, generates
# .shadowenv.d/510_ruby.lisp, trusts, and ensures the shell hook.
# Used by the dev CLI core as a pre-dispatch step for every command.
module ShadowenvRuby
  MIN_RUBY = Gem::Requirement.new(">= 2.7.0")
  LISP_FILENAME = "510_ruby.lisp"

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

  # Full provisioning: install Ruby via rbenv if needed, write lisp,
  # trust shadowenv, ensure shell hook. Idempotent.
  def setup!(ruby_version:, project_root:)
    root = project_root.to_s
    ruby_root = find_ruby_root(ruby_version)
    unless ruby_root
      if install_ruby_with_version_manager(ruby_version)
        ruby_root = find_ruby_root(ruby_version)
      end
      unless ruby_root
        $stderr.puts "dev: Ruby #{ruby_version} not found. Install: brew install rbenv ruby-build && rbenv install #{ruby_version}"
        return false
      end
    end

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

  def install_ruby_with_version_manager(version)
    path = path_with_brew_bin
    env = { "PATH" => path }
    return false unless system(env, "which", "rbenv", out: File::NULL, err: File::NULL)
    $stderr.puts "dev: Installing Ruby #{version} with rbenv (one-time)..."
    system(env, "rbenv", "install", version)
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

  def ensure_shadowenv_shell_hook!
    shell = ENV["SHELL"] || "/bin/sh"
    home = ENV["HOME"] || Dir.home
    hook_line = nil
    profile_path = nil

    if shell.include?("zsh")
      profile_path = File.join(home, ".zshrc")
      hook_line = 'eval "$(shadowenv init zsh)"'
    elsif shell.include?("bash")
      profile_path = File.join(home, ".bash_profile")
      hook_line = 'eval "$(shadowenv init bash)"'
      unless File.exist?(profile_path)
        bashrc = File.join(home, ".bashrc")
        profile_path = bashrc if File.exist?(bashrc)
      end
    elsif shell.include?("fish")
      fish_config_dir = File.join(home, ".config", "fish")
      FileUtils.mkdir_p(fish_config_dir)
      profile_path = File.join(fish_config_dir, "config.fish")
      hook_line = 'shadowenv init fish | source'
    end

    return false unless profile_path && hook_line

    if File.exist?(profile_path)
      content = File.read(profile_path)
      return :already_present if content.include?(hook_line) || content.include?("shadowenv init")
    end

    FileUtils.mkdir_p(File.dirname(profile_path))
    prompt_comment = if shell.include?("zsh")
      "# Optional: show active shadowenv in prompt: setopt PROMPT_SUBST && PROMPT='$(shadowenv prompt-widget)'\"$PROMPT\""
    elsif shell.include?("bash")
      "# Optional: show active shadowenv in prompt: PS1='$(shadowenv prompt-widget)'\"$PS1\""
    else
      "# Optional: see https://shopify.github.io/shadowenv/best-practices/#prompt-widget for fish"
    end
    File.open(profile_path, "a") do |f|
      f.puts "\n# Shadowenv (added by dev)"
      f.puts hook_line
      f.puts prompt_comment
    end
    :added
  rescue => e
    $stderr.puts "dev: Could not add shadowenv hook to shell profile: #{e.message}"
    false
  end
end
