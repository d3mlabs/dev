# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/data_root"
require "dev/build_container"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::DataRootTest < Minitest::Test
  test "on a Mac, path defaults to ~/.dev when no shared root exists" do
    Given "no env override and no shared root on disk"
    missing = File.join(Dir.mktmpdir, "absent")

    Expect
    Dev::DataRoot.path(env: {}, shared_root: missing, host_os: "darwin") == File.expand_path("~/.dev")
  end

  test "on a Mac, path resolves to the shared root when the directory exists" do
    Given "a provisioned shared root"
    shared = Dir.mktmpdir

    Expect "presence is the record - no config key"
    Dev::DataRoot.path(env: {}, shared_root: shared, host_os: "darwin") == shared
  end

  test "on Linux, path is /var/lib/dev whether or not it exists yet — a default needs nothing (dev#308)" do
    Given "a shared root on disk, which is the Mac's arrangement and not Linux's"
    shared = Dir.mktmpdir

    Expect
    Dev::DataRoot.path(env: {}, shared_root: shared, host_os: "linux") == "/var/lib/dev"
    Dev::DataRoot::LINUX_ROOT == "/var/lib/dev"
  end

  test "DEV_DATA_ROOT env wins over shared-root presence and the Linux default: #{host_os}" do
    Given "both an env override and a shared root"
    shared = Dir.mktmpdir

    Expect
    Dev::DataRoot.path(env: { "DEV_DATA_ROOT" => "~/elsewhere" }, shared_root: shared, host_os: host_os) ==
      File.expand_path("~/elsewhere")

    Where
    host_os  | _
    "darwin" | nil
    "linux"  | nil
  end

  test "blank DEV_DATA_ROOT reads as unset" do
    Expect
    Dev::DataRoot.path(env: { "DEV_DATA_ROOT" => "" }, shared_root: "/nope", host_os: "darwin") ==
      File.expand_path("~/.dev")
  end

  test "the Linux default is the container's mount point: one path on both sides of a Linux bind mount" do
    Expect
    Dev::DataRoot::LINUX_ROOT == Dev::BuildContainer::DATA_ROOT_MOUNT
  end

  test "expand maps the ~/.dev prefix through the resolved root" do
    Expect
    Dev::DataRoot.expand("~/.dev/engines/ue5", root: "/Users/Shared/dev") ==
      "/Users/Shared/dev/engines/ue5"
    Dev::DataRoot.expand("~/.dev", root: "/Users/Shared/dev") == "/Users/Shared/dev"
  end

  test "expand leaves non-data-root paths to plain expansion" do
    Expect "a ~/.dev* sibling is not the data root"
    Dev::DataRoot.expand("~/other/dir", root: "/Users/Shared/dev") == File.expand_path("~/other/dir")
    Dev::DataRoot.expand("~/.devstuff", root: "/Users/Shared/dev") == File.expand_path("~/.devstuff")
    Dev::DataRoot.expand("/abs/path", root: "/Users/Shared/dev") == "/abs/path"
  end
end
