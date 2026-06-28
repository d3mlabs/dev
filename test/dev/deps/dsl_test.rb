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

  test "register creates integration and DSL method in one call" do
    When "registering and using a custom integration"
    config = Dev::Deps.define do
      register :wow_curseforge, "WoWCurseforgeIntegration"

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

  test "ficsit() produces DependencyDeclaration with ficsit integration" do
    When "defining a ficsit mod dep"
    config = Dev::Deps.define do
      group :app do
        ficsit "SML", version: "^3.12.0"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "SML"
    decl.integration == :ficsit
    decl.group == :app
    decl.constraint["version"] == "^3.12.0"
  end

  test "ficsit() without version constraint produces declaration with empty constraint" do
    When "defining a ficsit dep without version"
    config = Dev::Deps.define do
      group :app do
        ficsit "AreaActions"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "AreaActions"
    decl.integration == :ficsit
    decl.constraint == {}
  end

  test "ficsit() with target passes target in constraint" do
    When "defining a ficsit dep with target"
    config = Dev::Deps.define do
      group :app do
        ficsit "MyMod", version: "^1.0", target: "LinuxServer"
      end
    end

    Then
    decl = config.declarations[0]
    decl.constraint["version"] == "^1.0"
    decl.constraint["target"] == "LinuxServer"
  end

  test "group platform: stamps the platform onto every declaration in the group" do
    When "defining a group pinned to a platform"
    config = Dev::Deps.define do
      group :integration, platform: "LinuxServer" do
        ficsit "SML", version: "^3.12.0"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "SML"
    decl.group == :integration
    decl.platform == "LinuxServer"
  end

  test "group without platform leaves declaration platform nil" do
    When "defining a group with no platform"
    config = Dev::Deps.define do
      group :app do
        ficsit "SML", version: "^3.12.0"
      end
    end

    Then
    config.declarations[0].platform.nil?
  end

  test "the same dep declared in two groups produces two declarations with each group's platform" do
    When "declaring SML in :app (default) and :integration (LinuxServer)"
    config = Dev::Deps.define do
      group :app do
        ficsit "SML", version: "^3.12.0"
      end
      group :integration, platform: "LinuxServer" do
        ficsit "SML", version: "^3.12.0"
      end
    end

    Then "both declarations exist, carrying their own group's platform"
    sml = config.declarations.select { |d| d.name == "SML" }
    sml.size == 2
    sml.map(&:platform).sort_by(&:to_s) == [nil, "LinuxServer"].sort_by(&:to_s)
    sml.map { |d| d.group }.sort == [:app, :integration]
  end

  test "gh() produces DependencyDeclaration named after the repo basename" do
    When "defining a gh release dep"
    config = Dev::Deps.define do
      group :build do
        gh "satisfactorymodding/UnrealEngine",
           tag: "5.6.1-css-83",
           assets: "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
           install_dir: "~/.dev/engines/unreal-engine-css"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "UnrealEngine"
    decl.integration == :gh
    decl.group == :build
    decl.constraint["repo"] == "satisfactorymodding/UnrealEngine"
    decl.constraint["tag"] == "5.6.1-css-83"
    decl.constraint["assets"] == "UnrealEngine-CSS-Editor-Linux.tar.zst.*"
    decl.constraint["install_dir"] == "~/.dev/engines/unreal-engine-css"
  end

  test "gh() build-from-source with github: shorthand names the dep and keeps the slug" do
    When "defining a gh build-from-source dep"
    config = Dev::Deps.define do
      group :game do
        gh "UnrealEngine",
           github: "EpicGames/UnrealEngine",
           tag: "5.6.1-release",
           build: "bin/build-ue.sh",
           install_dir: "~/.dev/engines/ue5"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "UnrealEngine"
    decl.integration == :gh
    decl.group == :game
    decl.constraint["repo"] == "EpicGames/UnrealEngine"
    decl.constraint["tag"] == "5.6.1-release"
    decl.constraint["build"] == "bin/build-ue.sh"
    decl.constraint["install_dir"] == "~/.dev/engines/ue5"
    !decl.constraint.key?("assets")
  end

  test "gh() stringifies a :none build recipe for header-only deps" do
    When "defining a header-only gh dep"
    config = Dev::Deps.define do
      group :app do
        gh "json", github: "nlohmann/json", tag: "v3.11.3", build: :none,
           install_dir: "~/.dev/headers/json"
      end
    end

    Then
    config.declarations[0].constraint["build"] == "none"
  end

  test "gh() raises when neither assets: nor build: is given" do
    When "defining a gh dep with no materialization"
    Dev::Deps.define do
      group :game do
        gh "UnrealEngine", github: "EpicGames/UnrealEngine", tag: "5.6.1-release",
           install_dir: "~/.dev/engines/ue5"
      end
    end

    Then
    raises ArgumentError
  end

  test "gh() raises when both assets: and build: are given" do
    When "defining a gh dep with both materializations"
    Dev::Deps.define do
      group :game do
        gh "UnrealEngine", github: "EpicGames/UnrealEngine", tag: "5.6.1-release",
           assets: "*.tar.zst.*", build: "bin/build-ue.sh", install_dir: "~/.dev/engines/ue5"
      end
    end

    Then
    raises ArgumentError
  end

  test "steam() produces a DependencyDeclaration with steam integration" do
    When "defining a steam dep in a LinuxServer group"
    config = Dev::Deps.define do
      group :integration, platform: "LinuxServer" do
        steam "SatisfactoryServer", app: 1690800, install_dir: "~/.dev/satisfactory-server"
      end
    end

    Then
    decl = config.declarations[0]
    decl.name == "SatisfactoryServer"
    decl.integration == :steam
    decl.group == :integration
    decl.platform == "LinuxServer"
    decl.constraint["app"] == 1690800
    decl.constraint["install_dir"] == "~/.dev/satisfactory-server"
    decl.constraint["branch"] == "public"
  end

  test "steam() accepts an explicit buildid pin" do
    When "defining a steam dep with a pinned buildid"
    config = Dev::Deps.define do
      group :integration, platform: "LinuxServer" do
        steam "SatisfactoryServer", app: 1690800, install_dir: "/srv", buildid: "15321746"
      end
    end

    Then
    config.declarations[0].constraint["buildid"] == "15321746"
  end

  test "brew with post_install stores callable in opts" do
    Given "a post_install callable"
    hook = ->(name, opts) {}

    When "defining a brew dep with post_install"
    config = Dev::Deps.define do
      group :build do
        brew "wwise-cli", tap: "d3mlabs/d3mlabs", post_install: hook
      end
    end

    Then
    entry = config.group("build")["brew"][0]
    entry.is_a?(Hash)
    entry["wwise-cli"]["post_install"] == hook
    entry["wwise-cli"]["tap"] == "d3mlabs/d3mlabs"
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

  test "post_install callable is extracted from spec and stored on declaration" do
    Given "a lambda post_install hook"
    hook = ->(dep, root) {}

    When "defining a cmake dep with post_install"
    config = Dev::Deps.define do
      group :test do
        cmake "googletest", github: "google/googletest", tag: "v1.17.0",
              post_install: hook
      end
    end

    Then
    decl = config.declarations[0]
    decl.post_install == hook
    !decl.constraint.key?("post_install")
  end

  test "post_install defaults to nil when not specified" do
    When "defining a cmake dep without post_install"
    config = Dev::Deps.define do
      group :app do
        cmake "boost", tag: "boost-1.90.0"
      end
    end

    Then
    config.declarations[0].post_install.nil?
  end

  test "last_config returns the most recently defined config" do
    When "defining a config"
    config = Dev::Deps.define do
      group :app do
        cmake "mylib", tag: "v1.0"
      end
    end

    Then "last_config matches the returned config"
    Dev::Deps.last_config == config
    Dev::Deps.last_config.declarations.size == 1
    Dev::Deps.last_config.declarations[0].name == "mylib"
  end
end
