# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/data_root"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::DataRootTest < Minitest::Test
  test "path defaults to ~/.dev when no shared root exists" do
    Given "no env override and no shared root on disk"
    missing = File.join(Dir.mktmpdir, "absent")

    Expect
    Dev::DataRoot.path(env: {}, shared_root: missing) == File.expand_path("~/.dev")
  end

  test "path resolves to the shared root when the directory exists" do
    Given "a provisioned shared root"
    shared = Dir.mktmpdir

    Expect "presence is the record - no config key"
    Dev::DataRoot.path(env: {}, shared_root: shared) == shared
  end

  test "DEV_DATA_ROOT env wins over shared-root presence" do
    Given "both an env override and a shared root"
    shared = Dir.mktmpdir

    Expect
    Dev::DataRoot.path(env: { "DEV_DATA_ROOT" => "~/elsewhere" }, shared_root: shared) ==
      File.expand_path("~/elsewhere")
  end

  test "blank DEV_DATA_ROOT reads as unset" do
    Expect
    Dev::DataRoot.path(env: { "DEV_DATA_ROOT" => "" }, shared_root: "/nope") ==
      File.expand_path("~/.dev")
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
