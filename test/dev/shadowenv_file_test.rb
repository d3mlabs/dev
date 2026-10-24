# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_context"
require "dev/shadowenv_file"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvFileTest < Minitest::Test
  BODY = "(provide \"ruby\" \"4.0.9\")\n(env/set \"RUBY_ROOT\" \"/x\")\n"

  test "on the host, write! puts the body in the named file, trusts the project and reports the write" do
    Given "a project root with no .shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-file-test-")

    When "writing the host side"
    written = Dev::ShadowenvFile.write!(project_root: tmpdir, filename: "510_ruby.lisp", body: BODY, inside: false)

    Then "the file is the body verbatim, shadowenv was trusted"
    1 * Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL) >> true
    written == true
    File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp")) == BODY

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "inside the container, write! writes a _container sibling gated on the inside marker, leaving the host file alone" do
    Given "a project whose host side is already activated"
    tmpdir = Dir.mktmpdir("shadowenv-file-test-")
    FileUtils.mkdir_p(File.join(tmpdir, ".shadowenv.d"))
    File.write(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp"), BODY)
    Kernel.stubs(:system).returns(true)

    When "writing the container side"
    Dev::ShadowenvFile.write!(project_root: tmpdir, filename: "510_ruby.lisp", body: BODY, inside: true)

    Then "the host file is untouched and the container file wraps the body in a when-let on the marker"
    File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp")) == BODY
    container = File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby_container.lisp"))
    container == "(when-let ((inside (env/get \"#{Dev::ContainerContext::MARKER}\")))\n#{BODY})\n"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "write! is a no-op when the file already holds the same content" do
    Given "a project already holding this exact file"
    tmpdir = Dir.mktmpdir("shadowenv-file-test-")
    FileUtils.mkdir_p(File.join(tmpdir, ".shadowenv.d"))
    File.write(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp"), BODY)

    When "writing the same body again"
    written = Dev::ShadowenvFile.write!(project_root: tmpdir, filename: "510_ruby.lisp", body: BODY, inside: false)

    Then "nothing is written or trusted"
    0 * Kernel.system
    written == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "the container sibling sorts after its host file, so inside the container it wins" do
    Expect "lexical order puts 510_ruby.lisp before 510_ruby_container.lisp"
    ["510_ruby_container.lisp", "510_ruby.lisp"].sort == ["510_ruby.lisp", "510_ruby_container.lisp"]
    Dev::ShadowenvFile.container_filename("510_ruby.lisp") == "510_ruby_container.lisp"
    Dev::ShadowenvFile.container_filename("515_brew.lisp") == "515_brew_container.lisp"
  end
end
