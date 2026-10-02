# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/ini_file"

transform!(RSpock::AST::Transformation)
class Dev::IniFileTest < Minitest::Test
  WSL_CONF = "[automount]\nenabled=true\n\n[boot]\nsystemd=true\ncommand=\"service cron start\"\n"

  test "value is section-scoped and case-insensitive on both names" do
    Given "a wsl.conf"
    ini = Dev::IniFile.parse(WSL_CONF)

    Expect
    ini.value(section, key).eql?(value)

    Where
    section     | key       | value
    "boot"      | "systemd" | "true"
    "BOOT"      | "SystemD" | "true"
    "automount" | "enabled" | "true"
    "boot"      | "enabled" | nil
    "network"   | "systemd" | nil
  end

  test "set rewrites in place, appends to a section, or creates the section; equality is by content" do
    Expect
    Dev::IniFile.parse(text).set(section, key, value).render == rendered
    Dev::IniFile.parse(rendered) == Dev::IniFile.parse(text).set(section, key, value)

    Where
    text                             | section | key       | value  | rendered
    "[boot]\nsystemd=false\n"        | "boot"  | "systemd" | "true" | "[boot]\nsystemd=true\n"
    "[boot]\ncommand=foo\n"          | "boot"  | "systemd" | "true" | "[boot]\ncommand=foo\nsystemd=true\n"
    "[boot]\ncommand=foo"            | "boot"  | "systemd" | "true" | "[boot]\ncommand=foo\nsystemd=true\n"
    "[boot]\n\n[user]\ndefault=jp\n" | "boot"  | "systemd" | "true" | "[boot]\nsystemd=true\n\n[user]\ndefault=jp\n"
    "[user]\ndefault=jp"             | "boot"  | "systemd" | "true" | "[user]\ndefault=jp\n\n[boot]\nsystemd=true\n"
    ""                               | "boot"  | "systemd" | "true" | "[boot]\nsystemd=true\n"
  end
end
