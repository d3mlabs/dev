# frozen_string_literal: true

require "minitest/autorun"
require "dev/deps"

class Dev::Deps::ConfigTest < Minitest::Test
  def setup
    Dev::Deps::Config.instance_variable_set(:@config, nil)
  end

  def test_define_sets_ruby_version
    Dev::Deps.define do
      ruby_version ">= 3.0.0"
    end

    assert_equal ">= 3.0.0", Dev::Deps::Config.ruby_version_requirement
  end

  def test_define_registers_gems
    Dev::Deps.define do
      gem "cli-ui"
      gem "rake", "~> 13.0"
    end

    assert_equal 2, Dev::Deps::Config.gems.size
    assert_equal "cli-ui", Dev::Deps::Config.gems[0]["name"]
    assert_equal "rake", Dev::Deps::Config.gems[1]["name"]
    assert_equal "~> 13.0", Dev::Deps::Config.gems[1]["version"]
  end

  def test_define_registers_taps
    Dev::Deps.define do
      tap "d3mlabs/d3mlabs"
      tap "local/tap", url: "file://./brew-tap"
    end

    taps = Dev::Deps::Config.taps
    assert_equal 2, taps.size
    assert_equal "d3mlabs/d3mlabs", taps["d3mlabs/d3mlabs"]["name"]
    assert_nil taps["d3mlabs/d3mlabs"]["url"]
    assert_equal "file://./brew-tap", taps["local/tap"]["url"]
  end

  def test_local_tap_names
    Dev::Deps.define do
      tap "remote/tap"
      tap "local/tap", url: "file://./brew-tap"
    end

    assert_equal ["local/tap"], Dev::Deps::Config.local_tap_names
  end

  def test_define_build_group_with_brew
    Dev::Deps.define do
      group :build do
        brew "ccache"
        brew "cmake"
        brew "powershell", version: "7.4.0", tap: "d3mlabs/d3mlabs"
      end
    end

    build = Dev::Deps::Config.group("build")
    assert_equal 3, build["brew"].size
    assert_equal "ccache", build["brew"][0]
    assert_equal "cmake", build["brew"][1]
    assert_equal({ "powershell" => { "version" => "7.4.0", "tap" => "d3mlabs/d3mlabs" } }, build["brew"][2])
  end

  def test_define_build_group_with_env
    Dev::Deps.define do
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

    build = Dev::Deps::Config.group("build")
    ci_brew = build["env"]["ci"]["brew"]
    dev_brew = build["env"]["dev"]["brew"]
    assert_equal ["ruby"], ci_brew
    assert_equal [{ "powershell" => { "cask" => true } }], dev_brew
  end

  def test_define_app_group_with_runtime_deps
    Dev::Deps.define do
      group :app do
        runtime "boost",
                url: "https://example.com/boost.tar.gz",
                tag: "boost-1.90.0",
                cmake_targets: ["stacktrace"],
                cmake_target_prefix: "Boost::"

        runtime "cereal",
                repo: "https://github.com/USCiLab/cereal",
                tag: "v1.3.2"
      end
    end

    app = Dev::Deps::Config.group("app")
    assert_equal 2, app["runtime"].size

    boost = app["runtime"][0]["boost"]
    assert_equal "https://example.com/boost.tar.gz", boost["url"]
    assert_equal "boost-1.90.0", boost["tag"]
    assert_equal ["stacktrace"], boost["cmake_targets"]
    assert_equal "Boost::", boost["cmake_target_prefix"]

    cereal = app["runtime"][1]["cereal"]
    assert_equal "https://github.com/USCiLab/cereal", cereal["repo"]
    assert_equal "v1.3.2", cereal["tag"]
  end

  def test_define_test_group
    Dev::Deps.define do
      group :test do
        runtime "googletest",
                repo: "https://github.com/google/googletest",
                tag: "v1.17.0",
                cmake_targets: ["gtest", "gmock"]
      end
    end

    test_group = Dev::Deps::Config.group("test")
    assert_equal 1, test_group["runtime"].size
    gtest = test_group["runtime"][0]["googletest"]
    assert_equal ["gtest", "gmock"], gtest["cmake_targets"]
  end

  def test_missing_group_returns_empty_defaults
    Dev::Deps.define {}
    nonexistent = Dev::Deps::Config.group("nonexistent")
    assert_equal [], nonexistent["runtime"]
    assert_equal [], nonexistent["brew"]
    assert_equal({}, nonexistent["env"])
  end

  def test_empty_gem_version_is_excluded
    Dev::Deps.define do
      gem "cli-ui"
    end

    g = Dev::Deps::Config.gems.first
    assert_equal "cli-ui", g["name"]
    refute g.key?("version")
  end

  def test_runtime_with_commit_pin
    Dev::Deps.define do
      group :app do
        runtime "entityx",
                repo: "https://github.com/alecthomas/entityx",
                commit: "ee3042f8b027"
      end
    end

    app = Dev::Deps::Config.group("app")
    entityx = app["runtime"][0]["entityx"]
    assert_equal "ee3042f8b027", entityx["commit"]
  end
end
