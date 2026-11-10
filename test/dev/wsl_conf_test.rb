# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/wsl_conf"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::WslConfTest < Minitest::Test
  test "systemd_enabled? reads [boot] systemd as WSL does — case-insensitively, true alone counting" do
    Expect
    Dev::WslConf.parse(text).systemd_enabled? == enabled

    Where
    text                                     | enabled
    ""                                       | false
    "[boot]\nsystemd=true\n"                 | true
    "[Boot]\nSystemd = True\n"               | true
    "[boot]\nsystemd=false\n"                | false
    "[boot]\ncommand=foo\n"                  | false
    "[automount]\nenabled=true\n"            | false
    "[wsl2]\nsystemd=true\n"                 | false
  end

  test "with_systemd_enabled sets the one key and leaves the rest of the file alone" do
    Expect
    Dev::WslConf.parse(text).with_systemd_enabled.render == rendered

    Where
    text                          | rendered
    ""                            | "[boot]\nsystemd=true\n"
    "[automount]\nenabled=true\n" | "[automount]\nenabled=true\n\n[boot]\nsystemd=true\n"
    "[boot]\nsystemd=false\n"     | "[boot]\nsystemd=true\n"
    "[boot]\ncommand=foo\n"       | "[boot]\ncommand=foo\nsystemd=true\n"
    "[boot]\nsystemd=true\n"      | "[boot]\nsystemd=true\n"
  end

  test "read takes the distro's file, empty when it does not exist yet" do
    Given "a directory with and without a wsl.conf"
    dir = Dir.mktmpdir("wsl-conf-test-")
    present = File.join(dir, "present.conf")
    File.write(present, "[boot]\nsystemd=true\n")
    absent = File.join(dir, "absent.conf")

    Expect
    Dev::WslConf.read(path: present).systemd_enabled?
    !Dev::WslConf.read(path: absent).systemd_enabled?
    Dev::WslConf.read(path: absent) == Dev::WslConf.parse("")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the distro's file has one home" do
    Expect
    Dev::WslConf::PATH == "/etc/wsl.conf"
  end
end
