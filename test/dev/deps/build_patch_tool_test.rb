# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/build_patch_tool"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BuildPatchToolTest < Minitest::Test
  test "binary names the host's executable inside the unpacked zip's layout" do
    Expect
    Dev::Deps::BuildPatchTool.binary(Pathname("/store/bpt"), host:) == Pathname("/store/bpt") / relative

    Where
    host      | relative
    "darwin"  | "Engine/Binaries/Mac/BuildPatchTool"
    "linux"   | "Engine/Binaries/Linux/BuildPatchTool"
    "windows" | "Engine/Binaries/Win64/BuildPatchTool.exe"
  end

  test "binary refuses a host the zip ships no binary for" do
    When
    Dev::Deps::BuildPatchTool.binary(Pathname("/store/bpt"), host: "freebsd")

    Then
    raises KeyError
  end

  test "run executes the binary with the arguments and the extra environment, returning its streams and status" do
    Given "a binary that echoes what it got"
    root = Pathname(Dir.mktmpdir("bpt-"))
    binary = root / "tool"
    binary.write("#!/bin/sh\necho \"$* ${DEV_EGS_CLIENT_SECRET}\"\necho oops >&2\nexit 2\n")
    binary.chmod(0o755)

    When
    out, err, status = Dev::Deps::BuildPatchTool.run(binary, ["-mode=UploadBinary", "-BuildVersion=1"], env: { "DEV_EGS_CLIENT_SECRET" => "s3cret" })

    Then
    out == "-mode=UploadBinary -BuildVersion=1 s3cret\n"
    err == "oops\n"
    status.exitstatus == 2

    Cleanup
    FileUtils.rm_rf(root)
  end
end
