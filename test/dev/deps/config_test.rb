# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ConfigTest < Minitest::Test
  test "define sets ruby version" do
    When
    config = Dev::Deps.define { ruby_version ">= 3.0.0" }

    Then
    config.ruby_version_requirement == ">= 3.0.0"
  end

  test "define registers gems with optional version" do
    When
    config = Dev::Deps.define do
      gem "cli-ui"
      gem "rake", "~> 13.0"
    end

    Then
    gems = config.gems
    gems.size == 2
    gems[0]["name"] == "cli-ui"
    !gems[0].key?("version")
    gems[1]["name"] == "rake"
    gems[1]["version"] == "~> 13.0"
  end

  test "define registers taps with optional url" do
    When
    config = Dev::Deps.define do
      tap "d3mlabs/d3mlabs"
      tap "local/tap", url: "file://./brew-tap"
    end

    Then
    taps = config.taps
    taps.size == 2
    taps["d3mlabs/d3mlabs"]["name"] == "d3mlabs/d3mlabs"
    taps["d3mlabs/d3mlabs"]["url"].nil?
    taps["local/tap"]["url"] == "file://./brew-tap"
  end

  test "local_tap_names returns only file:// taps" do
    When
    config = Dev::Deps.define do
      tap "remote/tap"
      tap "local/tap", url: "file://./brew-tap"
    end

    Then
    config.local_tap_names == ["local/tap"]
  end

  test "define build group with brew formulae" do
    When
    config = Dev::Deps.define do
      group :build do
        brew "ccache"
        brew "cmake"
        brew "powershell", version: "7.4.0", tap: "d3mlabs/d3mlabs"
      end
    end

    Then
    build = config.group("build")
    build["brew"].size == 3
    build["brew"][0] == "ccache"
    build["brew"][1] == "cmake"
    build["brew"][2] == { "powershell" => { "version" => "7.4.0", "tap" => "d3mlabs/d3mlabs" } }
  end

  test "define build group with env-specific brew" do
    When
    config = Dev::Deps.define do
      group :build do
        brew "cmake"
        env :ci do
          brew "ruby"
        end
        env :dev do
          brew "powershell", cask: true
        end
      end
    end

    Then
    build = config.group("build")
    build["env"]["ci"]["brew"] == ["ruby"]
    build["env"]["dev"]["brew"] == [{ "powershell" => { "cask" => true } }]
  end

  test "define app group with runtime deps" do
    When
    config = Dev::Deps.define do
      group :app do
        runtime "boost",
                url: "https://example.com/boost.tar.gz",
                tag: "boost-1.90.0",
                cmake_targets: ["stacktrace"],
                cmake_namespace: "Boost::"
        runtime "cereal",
                repo: "https://github.com/USCiLab/cereal",
                tag: "v1.3.2"
      end
    end

    Then
    app = config.group("app")
    app["runtime"].size == 2

    boost = app["runtime"][0]["boost"]
    boost["url"] == "https://example.com/boost.tar.gz"
    boost["tag"] == "boost-1.90.0"
    boost["cmake_targets"] == ["stacktrace"]
    boost["cmake_namespace"] == "Boost::"

    cereal = app["runtime"][1]["cereal"]
    cereal["repo"] == "https://github.com/USCiLab/cereal"
    cereal["tag"] == "v1.3.2"
  end

  test "define test group with cmake_targets" do
    When
    config = Dev::Deps.define do
      group :test do
        runtime "googletest",
                repo: "https://github.com/google/googletest",
                tag: "v1.17.0",
                cmake_targets: ["gtest", "gmock"]
      end
    end

    Then
    gtest = config.group("test")["runtime"][0]["googletest"]
    gtest["cmake_targets"] == ["gtest", "gmock"]
  end

  test "missing group returns empty defaults" do
    When
    config = Dev::Deps.define {}

    Then
    nonexistent = config.group("nonexistent")
    nonexistent["runtime"] == []
    nonexistent["brew"] == []
    nonexistent["env"] == {}
  end

  test "runtime with commit pin" do
    When
    config = Dev::Deps.define do
      group :app do
        runtime "entityx",
                repo: "https://github.com/alecthomas/entityx",
                commit: "ee3042f8b027"
      end
    end

    Then
    entityx = config.group("app")["runtime"][0]["entityx"]
    entityx["commit"] == "ee3042f8b027"
  end
end
