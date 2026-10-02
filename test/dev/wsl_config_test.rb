# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/wsl_config"

transform!(RSpock::AST::Transformation)
class Dev::WslConfigTest < Minitest::Test
  GAMEBOX = <<~INI
    [wsl2]
    memory=64GB
    processors=28
    swap=16GB
    autoMemoryReclaim=gradual
    networkingMode=mirrored
  INI

  test "parse reads the [wsl2] sizing keys and leaves the rest alone" do
    Given "the gamebox's .wslconfig"
    config = Dev::WslConfig.parse(GAMEBOX)

    Expect "the three keys dev cares about are typed, render is byte-exact, and equality is by content"
    config.processors == 28
    config.memory_gib == 64
    config.auto_memory_reclaim == "gradual"
    config.render == GAMEBOX
    config == Dev::WslConfig.parse(GAMEBOX)
    config != Dev::WslConfig.parse("")
  end

  test "parse answers nil for keys that are absent" do
    Expect "an empty file, a file without [wsl2], and a [wsl2] without sizes all read as unset"
    Dev::WslConfig.parse(text).processors.nil?
    Dev::WslConfig.parse(text).memory_gib.nil?
    Dev::WslConfig.parse(text).auto_memory_reclaim.nil?

    Where
    text                                   | _
    ""                                     | nil
    "[experimental]\nsparseVhd=true\n"     | nil
    "[wsl2]\nnetworkingMode=mirrored\n"    | nil
  end

  test "memory accepts WSL's unit suffixes and rounds up to whole GiB" do
    Expect
    Dev::WslConfig.parse("[wsl2]\nmemory=#{value}\n").memory_gib == gib

    Where
    value     | gib
    "64GB"    | 64
    "64gb"    | 64
    "512MB"   | 1
    "4096MB"  | 4
    "1TB"     | 1024
    " 8 GB "  | 8
  end

  test "a memory value WSL itself would reject raises instead of guessing" do
    Expect
    error = assert_raises(Dev::WslConfig::MalformedValueError) { Dev::WslConfig.parse("[wsl2]\nmemory=#{value}\n") }
    error.message.include?("memory=#{value}")

    Where
    value   | _
    "lots"  | nil
    "64"    | nil
    "8GiB"  | nil
  end

  test "with rewrites existing keys in place and preserves every other line" do
    Given "the gamebox config"
    config = Dev::WslConfig.parse(GAMEBOX)

    When "ratcheting both sizes"
    updated = config.with(processors: 32, memory_gib: 96)

    Then "only those two lines change, in their original positions"
    updated.render == GAMEBOX.sub("memory=64GB", "memory=96GB").sub("processors=28", "processors=32")
    updated.processors == 32
    updated.memory_gib == 96
    config.processors == 28

    Cleanup
    nil
  end

  test "with appends missing keys to the end of an existing [wsl2] section, before the next section" do
    Given "a [wsl2] section without sizes, followed by another section"
    text = "[wsl2]\nnetworkingMode=mirrored\n\n[experimental]\nsparseVhd=true\n"

    When "setting the sizes and the reclaim mode"
    updated = Dev::WslConfig.parse(text).with(processors: 8, memory_gib: 16, auto_memory_reclaim: "gradual")

    Then "the keys land inside [wsl2] and the blank line still separates the sections"
    updated.render ==
      "[wsl2]\nnetworkingMode=mirrored\nprocessors=8\nmemory=16GB\nautoMemoryReclaim=gradual\n\n[experimental]\nsparseVhd=true\n"

    Cleanup
    nil
  end

  test "with creates the [wsl2] section when the file has none" do
    Expect "an empty file and a file with only other sections both gain a [wsl2] block"
    Dev::WslConfig.parse(text).with(processors: 8, memory_gib: 16).render == rendered

    Where
    text                                | rendered
    ""                                  | "[wsl2]\nprocessors=8\nmemory=16GB\n"
    "[experimental]\nsparseVhd=true\n"  | "[experimental]\nsparseVhd=true\n\n[wsl2]\nprocessors=8\nmemory=16GB\n"
  end

  test "with leaves nil fields untouched" do
    Given "the gamebox config"
    config = Dev::WslConfig.parse(GAMEBOX)

    When "setting only the memory"
    updated = config.with(memory_gib: 96)

    Then "processors and autoMemoryReclaim are as they were"
    updated.processors == 28
    updated.auto_memory_reclaim == "gradual"
    updated.render == GAMEBOX.sub("memory=64GB", "memory=96GB")

    Cleanup
    nil
  end

  test "with preserves Windows line endings, section-name case, and key-name case" do
    Given "a file notepad wrote"
    text = "[WSL2]\r\nMemory=8GB\r\nProcessors=4\r\n"

    When "ratcheting and adding the reclaim mode"
    updated = Dev::WslConfig.parse(text).with(processors: 8, memory_gib: 16, auto_memory_reclaim: "gradual")

    Then "existing lines keep their spelling; the new line uses CRLF too"
    updated.render == "[WSL2]\r\nMemory=16GB\r\nProcessors=8\r\nautoMemoryReclaim=gradual\r\n"
    updated.processors == 8
    updated.memory_gib == 16

    Cleanup
    nil
  end
end
