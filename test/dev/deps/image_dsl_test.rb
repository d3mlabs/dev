# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ImageDSLTest < Minitest::Test
  FLOOR = "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3"

  test "image declares the floor as an :image dependency with the OS layer as its materialization" do
    When "declaring an image block"
    config = Dev::Deps.define do
      image "snappy-linux", from: FLOOR do
        platform "linux/amd64"
        apt "winbind", "dos2unix"
        apt "lib32stdc++6", "dos2unix"
      end
    end

    Then "one declaration: the floor is the source, the block's lines the materialization, sorted and unique"
    decls = config.declarations
    decls.size == 1
    decl = decls[0]
    decl.name == "snappy-linux"
    decl.integration == :image
    decl.source == FLOOR
    decl.constraint == {}
    decl.scope.group == :app
    decl.materialization == {
      "platform" => "linux/amd64",
      "apt" => ["dos2unix", "lib32stdc++6", "winbind"],
      "registry" => "ghcr.io/d3mlabs",
    }

    config.exports.empty? # never exported: an integration's manifest cannot declare a project's environment
  end

  test "registry defaults to the floor's — the image publishes beside what it derives from — and is overridable" do
    When
    config = Dev::Deps.define do
      image "a", from: FLOOR
      image "b", from: FLOOR, registry: "registry.example.com/team"
    end

    Then
    config.declarations.map { |d| d.materialization["registry"] } == ["ghcr.io/d3mlabs", "registry.example.com/team"]
  end

  test "a block without platform or apt is the floor alone: nil platform, no packages" do
    When
    config = Dev::Deps.define { image "bare", from: FLOOR }

    Then
    config.declarations[0].materialization == { "platform" => nil, "apt" => [], "registry" => "ghcr.io/d3mlabs" }
  end

  test "persist, volume and run_env shape the image's container and ride the materialization (dev#307)" do
    When "declaring the container's shape inside the block"
    config = Dev::Deps.define do
      image "snappy-linux", from: FLOOR do
        persist true
        volume "~/.dev/engines/unreal-engine-css:/ue"
        volume "~/.dev/wwise:/var/cache/dev/wwise-cli:ro"
        run_env "STAGING_DEPLOY_KEY" => "staging/deploy_key"
        run_env "WWISE_TOKEN" => "wwise/token"
      end
    end

    Then "each verb accumulates, as written"
    materialization = config.declarations[0].materialization
    materialization["persist"] == true
    materialization["volumes"] == ["~/.dev/engines/unreal-engine-css:/ue", "~/.dev/wwise:/var/cache/dev/wwise-cli:ro"]
    materialization["run_env"] == { "STAGING_DEPLOY_KEY" => "staging/deploy_key", "WWISE_TOKEN" => "wwise/token" }
  end

  test "a block declaring none of the container's shape carries none of its keys: the lock says nothing it was not told" do
    When
    config = Dev::Deps.define do
      image "x", from: FLOOR do
        persist false
      end
    end

    Then
    materialization = config.declarations[0].materialization
    !materialization.key?("persist")
    !materialization.key?("volumes")
    !materialization.key?("run_env")
  end

  test "several blocks declare several images: the design assumes none is the only one" do
    When
    config = Dev::Deps.define do
      image "linux", from: FLOOR
      image "linux-gpu", from: FLOOR do
        apt "libvulkan1"
      end
    end

    Then
    config.declarations.map(&:name) == ["linux", "linux-gpu"]
  end

  test "apt outside an image block is a load error that says where it belongs: #{where}" do
    When
    Dev::Deps.define(&block)

    Then
    error = raises(Dev::Deps::GroupDSL::AptOutsideImageError)
    error.message.include?("image")

    Where
    where        | block
    "top level"  | proc { apt "winbind" }
    "in a group" | proc { group(:build) { apt "winbind" } }
  end

  test "a store verb inside an image block is a load error pointing at the fat image (dev#309): #{verb}" do
    When
    Dev::Deps.define do
      image "x", from: FLOOR do
        send(verb, *args, **kwargs)
      end
    end

    Then
    error = raises(Dev::Deps::ImageDSL::StoreVerbInImageError)
    error.message.include?("#309")
    error.message.include?(verb.to_s)

    Where
    verb      | args                | kwargs
    :gh       | ["UnrealEngine"]    | { github: "d3mlabs/x", tag: "v1", assets: ["a"] }
    :brew     | ["cmake"]           | {}
    :gem      | ["rake"]            | {}
    :pip      | ["numpy"]           | {}
    :cmake    | ["boost"]           | { url: "https://e.com/b.tgz" }
    :steam    | ["server"]          | { app: 1 }
    :ficsit   | ["SML"]             | {}
    :luarocks | ["luaunit"]         | {}
    :xcode    | ["16.0"]            | {}
    :wwise    | ["wwise"]           | { sdk: "1", integration: "2", ue: "5.8" }
    :custom   | ["x"]               | { integration: :foo }
  end

  test "an apt package name that is not a Debian package name is a load error: #{name.inspect}" do
    When
    Dev::Deps.define do
      image "x", from: FLOOR do
        apt name
      end
    end

    Then
    raises Dev::Deps::ImageDSL::InvalidPackageNameError

    Where
    name            | _
    "libnss3=2:3.1" | "a version: a distro package cannot be pinned, the image is the pin"
    "Winbind"       | "upper case"
    ""              | "empty"
    "a b"           | "a space"
  end

  test "image without from: is an ArgumentError: the floor is not optional" do
    When
    Dev::Deps.define { image "x" }

    Then
    raises ArgumentError
  end

  test "image inside a group is not a verb there: the environment is the project's, not a group's" do
    When
    Dev::Deps.define { group(:build) { image "x", from: FLOOR } }

    Then
    raises NoMethodError
  end
end
