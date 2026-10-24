# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shadowenv_ruby"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvRubyTest < Minitest::Test
  # --- activate! ---

  test "activate! points the project shadowenv at a keg and writes .ruby-version from the locked version" do
    Given "a project root and the locked Ruby's keg"
    tmpdir = Dir.mktmpdir("shadowenv-activate-test-")
    keg = Pathname(tmpdir) / "Cellar" / "ruby@4.0.9" / "4.0.9"
    FileUtils.mkdir_p(keg / "bin")

    When "activating"
    Dev::ShadowenvRuby.activate!(keg: keg, version: "4.0.9", project_root: Pathname(tmpdir))

    Then "the lisp names the keg as RUBY_ROOT, .ruby-version carries the locked version, the shell hook is ensured"
    _ * Dev::ShadowenvRuby.ensure_shadowenv_shell_hook! >> :added
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp"))
    lisp.include?('(provide "ruby" "4.0.9")')
    lisp.include?(%((env/set "RUBY_ROOT" "#{keg}")))
    lisp.include?(%((env/prepend-to-pathlist "PATH" "#{keg / "bin"}")))
    File.read(File.join(tmpdir, ".ruby-version")) == "4.0.9\n"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end


  # --- gem_api_version ---

  test "gem_api_version returns #{expected} for #{version}" do
    Given "a ruby version string"
    result = Dev::ShadowenvRuby.gem_api_version(version)

    Expect "the correct format is returned"
    result == expected

    Where
    version  | expected
    "4.0.1"  | "4.0.0"
    "3.2.5"  | "3.2.0"
    "2.7.0"  | "2.7.0"
    "3.3.10" | "3.3.0"
    "4"      | "4.0"
  end


  # --- generate_ruby_lisp ---

  test "generate_ruby_lisp contains provide directive with version" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "the provide directive is present"
    assert_includes result, '(provide "ruby" "4.0.1")'
  end

  test "generate_ruby_lisp sets RUBY_ROOT" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "RUBY_ROOT is set"
    assert_includes result, '(env/set "RUBY_ROOT" "/opt/ruby/4.0.1")'
  end

  test "generate_ruby_lisp prepends ruby bin to PATH" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "PATH includes ruby bin"
    assert_includes result, '(env/prepend-to-pathlist "PATH" "/opt/ruby/4.0.1/bin")'
  end

  test "generate_ruby_lisp sets RUBY_VERSION env var" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "RUBY_VERSION is set"
    assert_includes result, '(env/set "RUBY_VERSION" "4.0.1")'
  end

  test "generate_ruby_lisp derives GEM_HOME from HOME at activation time" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "GEM_HOME composes HOME/.gem/<engine>/<version> and rides GEM_PATH and PATH"
    result.include?('(path-concat (env/get "HOME") ".gem" (env/get "RUBY_ENGINE") (env/get "RUBY_VERSION"))')
    result.include?('(env/set "GEM_HOME" gem-home)')
    result.include?('(env/prepend-to-pathlist "GEM_PATH" gem-home)')
    result.include?('(env/prepend-to-pathlist "PATH" (path-concat gem-home "bin"))')
  end

  # --- ensure_shadowenv_shell_hook! ---

  test "ensure_shadowenv_shell_hook! adds hook to zshrc when not present" do
    Given "a zsh shell with no .zshrc"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    result = Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the hook is added to .zshrc"
    result == :added
    zshrc = File.read(File.join(tmpdir, ".zshrc"))
    assert_includes zshrc, 'eval "$(shadowenv init zsh)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! returns :already_present when hook exists" do
    Given "a zsh shell with existing shadowenv hook in .zshrc"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    File.write(File.join(tmpdir, ".zshrc"), 'eval "$(shadowenv init zsh)"')

    When "we ensure the shell hook"
    result = Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "it reports already present"
    result == :already_present

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! recognizes an RC written before the shared installer" do
    Given "a zsh .zshrc carrying the historical dev marker"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    File.write(File.join(tmpdir, ".zshrc"), "\n# Shadowenv (added by dev)\neval \"$(shadowenv init zsh)\"\n")
    before = File.read(File.join(tmpdir, ".zshrc"))

    When "we ensure the shell hook"
    result = Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the old install is recognized, not re-appended"
    result == :already_present
    File.read(File.join(tmpdir, ".zshrc")) == before

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! adds hook to bash_profile for bash" do
    Given "a bash shell with no .bash_profile"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/bash"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    result = Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the hook is added to .bash_profile"
    result == :added
    bash_profile = File.read(File.join(tmpdir, ".bash_profile"))
    assert_includes bash_profile, 'eval "$(shadowenv init bash)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! reports false when the RC file cannot be written" do
    Given "a zsh shell whose home directory is not writable"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    FileUtils.chmod(0o500, tmpdir)

    When "we ensure the shell hook"
    result = Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the failure is reported as false instead of raising"
    result == false

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.chmod(0o700, tmpdir)
    FileUtils.rm_rf(tmpdir)
  end
end
