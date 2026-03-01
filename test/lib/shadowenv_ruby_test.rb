# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_ruby"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvRubyTest < Minitest::Test
  # --- resolve_ruby_version ---

  test "resolve_ruby_version returns explicit version when provided" do
    Given "an explicit version above the minimum"
    ruby_version = "4.0.1"

    When "we resolve with an explicit version"
    result = ShadowenvRuby.resolve_ruby_version(ruby_version)

    Then "the explicit version is returned and homebrew version is ignored"
    _ * ShadowenvRuby.detect_homebrew_ruby_version >> "3.2.0"
    result == ruby_version
  end

  test "resolve_ruby_version falls back to Homebrew when explicit is nil" do
    Given "no explicit version"
    ruby_version = nil

    When "we resolve with nil"
    result = ShadowenvRuby.resolve_ruby_version(nil)

    Then "the Homebrew version is returned"
    _ * ShadowenvRuby.detect_homebrew_ruby_version >> "3.3.0"
    result == "3.3.0"
  end

  test "resolve_ruby_version aborts when no version is available" do
    Given "no explicit version"
    ruby_version = nil

    When "we resolve the ruby version"
    ShadowenvRuby.resolve_ruby_version(ruby_version)

    Then "it aborts"
    _ * ShadowenvRuby.detect_homebrew_ruby_version >> nil
    1 * Kernel.abort("dev: No Ruby version specified in dev.yml and Homebrew Ruby not found. Run: brew install ruby")
  end

  test "resolve_ruby_version aborts when version is below minimum" do
    Given "a version below the minimum"
    ruby_version = "2.6.0"

    When "we resolve the ruby version"
    ShadowenvRuby.resolve_ruby_version(ruby_version)

    Then "it aborts for version below 2.7.0"
    1 * Kernel.abort("dev: Resolved Ruby 2.6.0 is below dev's minimum (>= 2.7.0). Pin a newer version in dev.yml or run: brew upgrade ruby")
  end

  # --- provisioned? ---

  test "provisioned? returns true when lisp file matches version" do
    Given "a project root with matching 510_ruby.lisp"
    ruby_version = "4.0.1"
    tmpdir = Dir.mktmpdir("shadowenv-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_ruby.lisp"),
      ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", ruby_version)
    )

    Expect ".provisioned? returns true when lisp file matches version"
    ShadowenvRuby.provisioned?(ruby_version, project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when lisp file has different version" do
    Given "a project root with 510_ruby.lisp for a different version"
    tmpdir = Dir.mktmpdir("shadowenv-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_ruby.lisp"),
      ShadowenvRuby.generate_ruby_lisp("/opt/ruby/3.2.0", "3.2.0")
    )

    Expect ".provisioned? returns false when lisp file has different version"
    ShadowenvRuby.provisioned?("4.0.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when .shadowenv.d does not exist" do
    Given "a project root without .shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-test-")

    Expect ".provisioned? returns false when .shadowenv.d does not exist"
    result = ShadowenvRuby.provisioned?("4.0.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- gem_api_version ---

  test "gem_api_version returns #{expected} for #{version}" do
    Given "a ruby version string"
    result = ShadowenvRuby.gem_api_version(version)

    Expect "the correct format is returned"
    result == expected

    Where
    version  | expected
    "4.0.1"  | "4.0.0"
    "3.2.5"  | "3.2.0"
    "2.7.0"  | "2.7.0"
    "3.3.10" | "3.3.0"
  end

  # --- generate_ruby_lisp ---

  test "generate_ruby_lisp contains provide directive with version" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "the provide directive is present"
    assert_includes result, '(provide "ruby" "4.0.1")'
  end

  test "generate_ruby_lisp sets RUBY_ROOT" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "RUBY_ROOT is set"
    assert_includes result, '(env/set "RUBY_ROOT" "/opt/ruby/4.0.1")'
  end

  test "generate_ruby_lisp prepends ruby bin to PATH" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "PATH includes ruby bin"
    assert_includes result, '(env/prepend-to-pathlist "PATH" "/opt/ruby/4.0.1/bin")'
  end

  test "generate_ruby_lisp sets RUBY_VERSION env var" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "RUBY_VERSION is set"
    assert_includes result, '(env/set "RUBY_VERSION" "4.0.1")'
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
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

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
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "it reports already present"
    result == :already_present

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
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the hook is added to .bash_profile"
    result == :added
    bash_profile = File.read(File.join(tmpdir, ".bash_profile"))
    assert_includes bash_profile, 'eval "$(shadowenv init bash)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end
end
