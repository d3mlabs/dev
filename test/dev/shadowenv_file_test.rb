# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shadowenv_file"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvFileTest < Minitest::Test
  BODY = "(provide \"ruby\" \"4.0.9\")\n(env/set \"RUBY_ROOT\" \"/x\")\n"

  test "write! puts the body in the named file under .shadowenv.d, trusts the project and reports the write" do
    Given "a project root with no .shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-file-test-")

    When
    written = Dev::ShadowenvFile.write!(project_root: tmpdir, filename: "510_ruby.lisp", body: BODY)

    Then "the file is the body verbatim, shadowenv was trusted"
    1 * Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL) >> true
    written == true
    File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp")) == BODY

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "write! is a no-op when the file already holds the same content" do
    Given "a project already holding this exact file"
    tmpdir = Dir.mktmpdir("shadowenv-file-test-")
    FileUtils.mkdir_p(File.join(tmpdir, ".shadowenv.d"))
    File.write(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp"), BODY)

    When "writing the same body again"
    written = Dev::ShadowenvFile.write!(project_root: tmpdir, filename: "510_ruby.lisp", body: BODY)

    Then "nothing is written or trusted"
    0 * Kernel.system
    written == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "write! replaces a file whose content differs, and trusts again" do
    Given "a project holding an older activation"
    tmpdir = Dir.mktmpdir("shadowenv-file-test-")
    FileUtils.mkdir_p(File.join(tmpdir, ".shadowenv.d"))
    File.write(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp"), "(provide \"ruby\" \"3.3.0\")\n")

    When
    written = Dev::ShadowenvFile.write!(project_root: tmpdir, filename: "510_ruby.lisp", body: BODY)

    Then
    1 * Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL) >> true
    written == true
    File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp")) == BODY

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end
