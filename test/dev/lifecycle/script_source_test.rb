# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ScriptSourceTest < Minitest::Test
  test "#{description}: mentions?(DEV_INSTALL) is #{expected}" do
    Given "a project with a build script reading the old key and a data file beside it"
    root = Pathname(Dir.mktmpdir("script-source-"))
    (root / "bin").mkpath
    (root / "bin/build.sh").write("#!/bin/sh\ncp -R out/. \"$DEV_INSTALL\"/\n")
    (root / "bin/layout").write("#!/bin/sh\ncp -R out/. \"$DEV_STAGE\"/\n")
    (root / "bin/noise.bin").write("\xff\xfe".b)
    source = Dev::Lifecycle::ScriptSource.new(command:, project_root: root)

    Expect
    source.mentions?("DEV_INSTALL") == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    description                                     | command                        | expected
    "the line itself reads it"                      | 'cp -R out/. "$DEV_INSTALL"/'  | true
    "a file the line names reads it"                | "./bin/build.sh"               | true
    "a file named after an interpreter reads it"    | "sh bin/build.sh --fast"       | true
    "the file the line names reads the new key"     | "./bin/layout"                 | false
    "the line names no file"                        | "make stage"                   | false
    "the line names a file that is not there"       | "./bin/missing.sh"             | false
    "a binary file named on the line is just bytes" | "./bin/layout bin/noise.bin"   | false
  end
end
