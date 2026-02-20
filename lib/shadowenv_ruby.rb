# frozen_string_literal: true

require "fileutils"

# Generates .shadowenv.d/510_ruby.lisp from dependencies.rb and auto-trusts.
# Detects Ruby via rbenv, chruby, or asdf. Used by dev up.

def find_ruby_root(version)
  home = ENV["HOME"] || Dir.home
  # rbenv
  rbenv_root = ENV["RBENV_ROOT"] || File.join(home, ".rbenv")
  rbenv_path = File.join(rbenv_root, "versions", version)
  return File.expand_path(rbenv_path) if File.directory?(rbenv_path)
  # chruby: /opt/rubies or ~/.rubies
  [File.join("/opt/rubies", version), File.join(home, ".rubies", version)].each do |p|
    return File.expand_path(p) if File.directory?(p)
  end
  # asdf
  asdf_dir = ENV["ASDF_DATA_DIR"] || File.join(home, ".asdf")
  asdf_path = File.join(asdf_dir, "installs", "ruby", version)
  return File.expand_path(asdf_path) if File.directory?(asdf_path)
  nil
end

def gem_api_version(ruby_version)
  # e.g. 2.7.6 -> 2.7.0, 3.2.0 -> 3.2.0
  parts = ruby_version.split(".").map(&:to_i)
  return "#{parts[0]}.#{parts[1]}.0" if parts.size >= 2
  "#{ruby_version}.0"
end

def generate_ruby_lisp(ruby_root, ruby_version)
  gem_root = File.join(ruby_root, "lib", "ruby", "gems", gem_api_version(ruby_version))
  # Fallback if layout is different (e.g. asdf)
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
    # Also check .bashrc if .bash_profile doesn't exist
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

  # Check if hook is already present
  if File.exist?(profile_path)
    content = File.read(profile_path)
    return true if content.include?(hook_line) || content.include?("shadowenv init")
  end

  # Add hook to profile (prompt widget is commented out; uncomment to show active shadowenv in prompt)
  FileUtils.mkdir_p(File.dirname(profile_path))
  prompt_comment = if shell.include?("zsh")
    "# Optional: show active shadowenv in prompt: setopt PROMPT_SUBST && PROMPT='$(shadowenv prompt-widget)'\"$PROMPT\""
  elsif shell.include?("bash")
    "# Optional: show active shadowenv in prompt: PS1='$(shadowenv prompt-widget)'\"$PS1\""
  else
    "# Optional: see https://shopify.github.io/shadowenv/best-practices/#prompt-widget for fish"
  end
  File.open(profile_path, "a") do |f|
    f.puts "\n# Shadowenv (added by dev up)"
    f.puts hook_line
    f.puts prompt_comment
  end
  puts "  Added shadowenv hook to #{profile_path}"
  puts "  Restart your shell or run: source #{profile_path}"
  true
rescue => e
  puts "  ⚠️  Could not add shadowenv hook to shell profile: #{e.message}"
  false
end

def setup_shadowenv_ruby!(dev_root)
  load File.join(dev_root, "dependencies.rb") unless defined?(RUBY_VERSION_REQUESTED)
  version = RUBY_VERSION_REQUESTED.to_s.strip
  ruby_root = find_ruby_root(version)
  unless ruby_root
    puts "  ⚠️  Ruby #{version} not found (checked rbenv, chruby, asdf). Install it (e.g. rbenv install #{version}) and run dev up again."
    return false
  end

  shadowenv_d = File.join(dev_root, ".shadowenv.d")
  FileUtils.mkdir_p(shadowenv_d)
  lisp_path = File.join(shadowenv_d, "510_ruby.lisp")
  File.write(lisp_path, generate_ruby_lisp(ruby_root, version))
  puts "  Generated #{lisp_path}"

  # Auto-trust so the user doesn't have to run shadowenv trust
  if system("shadowenv", "trust")
    puts "  Trusted .shadowenv.d"
  else
    puts "  ⚠️  Run 'shadowenv trust' in the repo root to activate (or install shadowenv: brew install shadowenv)"
  end

  # Ensure shell hook is installed
  ensure_shadowenv_shell_hook!

  true
end
