# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ConfigTest < Minitest::Test
  test "define sets ruby version via the first-class ruby directive" do
    When
    config = Dev::Deps.define { ruby "4.0.5" }

    Then
    config.ruby_version_requirement == "4.0.5"
  end

  test "define registers gems as bundler declarations with optional version" do
    When
    config = Dev::Deps.define do
      gem "cli-ui"
      gem "rake", "~> 13.0"
    end

    Then
    gems = config.declarations.select { |d| d.integration == :bundler }
    gems.size == 2
    gems[0].name == "cli-ui"
    gems[0].group == Dev::Deps::DSL::DEFAULT_GEM_GROUP
    !gems[0].constraint.key?("version")
    gems[1].name == "rake"
    gems[1].constraint["version"] == "~> 13.0"
  end

  test "define registers group-scoped gems with the group as bundler group" do
    When
    config = Dev::Deps.define do
      group :test do
        gem "minitest", "~> 5.0"
      end
    end

    Then
    decl = config.declarations.find { |d| d.name == "minitest" }
    decl.integration == :bundler
    decl.group == :test
    decl.constraint["version"] == "~> 5.0"
  end

  test "define registers taps as Tap objects" do
    When
    config = Dev::Deps.define do
      tap "d3mlabs/d3mlabs"
      tap "local/tap", url: "file://./brew-tap"
    end

    Then
    taps = config.taps
    taps.size == 2
    taps[0].is_a?(Dev::Deps::Tap)
    taps[0].name == "d3mlabs/d3mlabs"
    taps[0].url.nil?
    taps[1].name == "local/tap"
    taps[1].url == URI("file://./brew-tap")
  end

  test "Tap#local? returns true for file:// taps" do
    When
    config = Dev::Deps.define do
      tap "remote/tap"
      tap "local/tap", url: "file://./brew-tap"
    end

    Then
    local_taps = config.taps.select(&:local?)
    local_taps.size == 1
    local_taps[0].name == "local/tap"
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

  test "define app group with cmake deps produces declarations" do
    When
    config = Dev::Deps.define do
      group :app do
        cmake "boost",
              url: "https://example.com/boost.tar.gz",
              tag: "boost-1.90.0",
              cmake_targets: ["stacktrace"],
              cmake_namespace: "Boost::"
        cmake "cereal",
              repo: "https://github.com/USCiLab/cereal",
              tag: "v1.3.2"
      end
    end

    Then
    decls = config.declarations.select { |d| d.group == :app }
    decls.size == 2

    decls[0].name == "boost"
    decls[0].constraint["url"] == "https://example.com/boost.tar.gz"
    decls[0].constraint["tag"] == "boost-1.90.0"
    decls[0].constraint["cmake_targets"] == ["stacktrace"]
    decls[0].constraint["cmake_namespace"] == "Boost::"

    decls[1].name == "cereal"
    decls[1].constraint["repo"] == "https://github.com/USCiLab/cereal"
    decls[1].constraint["tag"] == "v1.3.2"
  end

  test "define test group with cmake_targets" do
    When
    config = Dev::Deps.define do
      group :test do
        cmake "googletest",
              repo: "https://github.com/google/googletest",
              tag: "v1.17.0",
              cmake_targets: ["gtest", "gmock"]
      end
    end

    Then
    decl = config.declarations.find { |d| d.name == "googletest" }
    decl.constraint["cmake_targets"] == ["gtest", "gmock"]
  end

  test "missing group returns empty defaults" do
    When
    config = Dev::Deps.define {}

    Then
    nonexistent = config.group("nonexistent")
    nonexistent["brew"] == []
    nonexistent["env"] == {}
  end

  test "cmake dep with commit pin" do
    When
    config = Dev::Deps.define do
      group :app do
        cmake "entityx",
              repo: "https://github.com/alecthomas/entityx",
              commit: "ee3042f8b027"
      end
    end

    Then
    decl = config.declarations.find { |d| d.name == "entityx" }
    decl.constraint["commit"] == "ee3042f8b027"
  end

  test "brew dual-writes to both groups and declarations" do
    When
    config = Dev::Deps.define do
      group :build do
        brew "cmake"
        brew "powershell", version: "7.4.0", tap: "d3mlabs/d3mlabs"
        env :ci do
          brew "ruby"
        end
      end
    end

    Then "the container groups path is unchanged and brew also rides the lockfile pipeline"
    config.group("build")["brew"].size == 2
    config.group("build")["env"]["ci"]["brew"] == ["ruby"]
    brew_decls = config.declarations.select { |d| d.integration == :brew }
    brew_decls.map(&:name).sort == %w[cmake powershell ruby]
    brew_decls.all? { |d| d.group == :build }
    brew_decls.find { |d| d.name == "powershell" }.constraint["tap"] == "d3mlabs/d3mlabs"
    # env is a first-class declaration field, never smuggled into the constraint.
    brew_decls.find { |d| d.name == "ruby" }.env == "ci"
    brew_decls.find { |d| d.name == "ruby" }.constraint["env"].nil?
  end
end
