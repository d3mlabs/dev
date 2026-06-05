# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DSLTest < Minitest::Test
  test "cmake() method stores deps with integration tag" do
    When "defining a cmake dep"
    config = Dev::Deps.define do
      group :app do
        cmake "boost",
              url: "https://example.com/boost.tar.gz",
              tag: "boost-1.90.0"
      end
    end

    Then
    app = config.group("app")
    app["runtime"].size == 1
    boost = app["runtime"][0]["boost"]
    boost["url"] == "https://example.com/boost.tar.gz"
    boost["integration"] == "cmake"
  end

  test "cmake() is aliased to runtime() for backward compatibility" do
    When "defining via runtime()"
    config = Dev::Deps.define do
      group :app do
        runtime "cereal", repo: "https://github.com/USCiLab/cereal", tag: "v1.3.2"
      end
    end

    Then
    app = config.group("app")
    app["runtime"].size == 1
    cereal = app["runtime"][0]["cereal"]
    cereal["repo"] == "https://github.com/USCiLab/cereal"
  end

  test "github: shorthand expands org/repo to full URL" do
    When "defining with github: shorthand"
    config = Dev::Deps.define do
      group :app do
        cmake "cereal", github: "USCiLab/cereal", tag: "v1.3.2"
      end
    end

    Then
    cereal = config.group("app")["runtime"][0]["cereal"]
    cereal["repo"] == "https://github.com/USCiLab/cereal"
    !cereal.key?("github")
  end

  test "github: shorthand with org only appends dep name" do
    When "defining with org-only github: shorthand"
    config = Dev::Deps.define do
      group :app do
        cmake "axmol", github: "axmolengine", tag: "v2.11.2"
      end
    end

    Then
    axmol = config.group("app")["runtime"][0]["axmol"]
    axmol["repo"] == "https://github.com/axmolengine/axmol"
  end

  test "luarocks() method stores deps with luarocks integration" do
    When "defining a luarocks dep"
    config = Dev::Deps.define do
      group :test do
        luarocks "luaunit", ">=3.5"
      end
    end

    Then
    test_group = config.group("test")
    test_group["runtime"].size == 1
    luaunit = test_group["runtime"][0]["luaunit"]
    luaunit["integration"] == "luarocks"
    luaunit["constraint"] == ">=3.5"
  end

  test "custom() method stores deps with arbitrary integration" do
    When "defining a custom integration dep"
    config = Dev::Deps.define do
      group :app do
        custom "CombatMode", integration: :wow_curseforge, version: ">=1.0"
      end
    end

    Then
    app = config.group("app")
    app["runtime"].size == 1
    cm = app["runtime"][0]["CombatMode"]
    cm["integration"] == "wow_curseforge"
    cm["version"] == ">=1.0"
  end

  test "lua_version() stores the lua version" do
    When "defining a lua version"
    config = Dev::Deps.define do
      lua_version "5.1"
    end

    Then
    config.lua_version == "5.1"
  end

  test "register_integration and register_method create DSL methods" do
    When "registering and using a custom method"
    config = Dev::Deps.define do
      register_integration :wow_curseforge, "WoWCurseforgeIntegration"
      register_method :wow_curseforge

      group :app do
        wow_curseforge "CombatMode", version: ">=1.0"
      end
    end

    Then
    app = config.group("app")
    cm = app["runtime"][0]["CombatMode"]
    cm["integration"] == "wow_curseforge"
    config.registered_integrations[:wow_curseforge] == "WoWCurseforgeIntegration"
  end

  test "runtime raises EmptyNameError for empty name" do
    When "defining a runtime dep with empty name"
    Dev::Deps.define do
      group :app do
        runtime "", repo: "https://example.com"
      end
    end

    Then
    raises Dev::Deps::GroupDSL::EmptyNameError
  end

  test "brew raises EmptyNameError for empty name" do
    When "defining a brew dep with empty name"
    Dev::Deps.define do
      group :build do
        brew ""
      end
    end

    Then
    raises Dev::Deps::GroupDSL::EmptyNameError
  end
end
