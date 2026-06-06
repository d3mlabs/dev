# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DSLTest < Minitest::Test
  test "cmake() produces DependencyDeclaration with cmake integration" do
    When "defining a cmake dep"
    config = Dev::Deps.define do
      group :app do
        cmake "boost",
              url: "https://example.com/boost.tar.gz",
              tag: "boost-1.90.0"
      end
    end

    Then
    decls = config.declarations
    decls.size == 1
    decls[0].name == "boost"
    decls[0].integration == :cmake
    decls[0].group == :app
    decls[0].constraint["url"] == "https://example.com/boost.tar.gz"
    decls[0].constraint["tag"] == "boost-1.90.0"
  end

  test "github: shorthand expands org/repo to full URL" do
    When "defining with github: shorthand"
    config = Dev::Deps.define do
      group :app do
        cmake "cereal", github: "USCiLab/cereal", tag: "v1.3.2"
      end
    end

    Then
    decl = config.declarations[0]
    decl.constraint["repo"] == "https://github.com/USCiLab/cereal"
    !decl.constraint.key?("github")
  end

  test "github: shorthand with org only appends dep name" do
    When "defining with org-only github: shorthand"
    config = Dev::Deps.define do
      group :app do
        cmake "axmol", github: "axmolengine", tag: "v2.11.2"
      end
    end

    Then
    config.declarations[0].constraint["repo"] == "https://github.com/axmolengine/axmol"
  end

  test "luarocks() produces DependencyDeclaration with luarocks integration" do
    When "defining a luarocks dep"
    config = Dev::Deps.define do
      group :test do
        luarocks "luaunit", ">=3.5"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "luaunit"
    decl.integration == :luarocks
    decl.group == :test
    decl.constraint["constraint"] == ">=3.5"
  end

  test "custom() produces DependencyDeclaration with arbitrary integration" do
    When "defining a custom integration dep"
    config = Dev::Deps.define do
      group :app do
        custom "CombatMode", integration: :wow_curseforge, version: ">=1.0"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "CombatMode"
    decl.integration == :wow_curseforge
    decl.constraint["version"] == ">=1.0"
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
    decl = config.declarations[0]
    decl.name == "CombatMode"
    decl.integration == :wow_curseforge
    config.registered_integrations[:wow_curseforge] == "WoWCurseforgeIntegration"
  end

  test "cmake raises EmptyNameError for empty name" do
    When "defining a cmake dep with empty name"
    Dev::Deps.define do
      group :app do
        cmake "", url: "https://example.com"
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

  test "declarations span multiple groups" do
    When "defining deps in app and test groups"
    config = Dev::Deps.define do
      group :app do
        cmake "boost", tag: "boost-1.90.0"
      end
      group :test do
        cmake "googletest", tag: "v1.17.0"
      end
    end

    Then
    config.declarations.size == 2
    config.declarations[0].group == :app
    config.declarations[1].group == :test
  end

  test "user-defined groups produce declarations with custom group names" do
    When "defining a custom group"
    config = Dev::Deps.define do
      group :deploy do
        cmake "deploy_tool", tag: "v1.0"
      end
    end

    Then
    config.declarations.size == 1
    config.declarations[0].group == :deploy
  end
end
