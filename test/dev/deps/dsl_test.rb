# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DSLTest < Minitest::Test
  test "cmake() produces ScopedDeclaration with cmake integration" do
    When "defining a cmake dep"
    config = Dev::Deps.define do
      group :app do
        cmake "boost",
          url: "https://example.com/boost.tar.gz",
          tag: "boost-1.90.0"
      end
    end

    Then "the url is the source coordinate; only the tag remains a constraint"
    decls = config.declarations
    decls.size == 1
    decls[0].name == "boost"
    decls[0].integration == :cmake
    decls[0].scope.group == :app
    decls[0].source == "https://example.com/boost.tar.gz"
    decls[0].constraint["tag"] == "boost-1.90.0"
    !decls[0].constraint.key?("url")
  end

  test "github: shorthand expands org/repo to full URL" do
    When "defining with github: shorthand"
    config = Dev::Deps.define do
      group :app do
        cmake "cereal", github: "USCiLab/cereal", tag: "v1.3.2"
      end
    end

    Then "the expanded URL lands as the source, not a constraint key"
    decl = config.declarations[0]
    decl.source == "https://github.com/USCiLab/cereal"
    !decl.constraint.key?("github")
    !decl.constraint.key?("repo")
  end

  test "github: shorthand with org only appends dep name" do
    When "defining with org-only github: shorthand"
    config = Dev::Deps.define do
      group :app do
        cmake "axmol", github: "axmolengine", tag: "v2.11.2"
      end
    end

    Then
    config.declarations[0].source == "https://github.com/axmolengine/axmol"
  end

  test "luarocks() produces ScopedDeclaration with luarocks integration" do
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
    decl.scope.group == :test
    decl.constraint["constraint"] == ">=3.5"
  end

  test "custom() produces ScopedDeclaration with arbitrary integration" do
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

  test "ficsit() produces ScopedDeclaration with ficsit integration" do
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
    decl.scope.group == :app
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

  test "ficsit() with target rides materialization, not the constraint" do
    When "defining a ficsit dep with target"
    config = Dev::Deps.define do
      group :app do
        ficsit "MyMod", version: "^1.0", target: "LinuxServer"
      end
    end

    Then "which artifact to fetch is an install instruction"
    decl = config.declarations[0]
    decl.constraint["version"] == "^1.0"
    decl.materialization["target"] == "LinuxServer"
    !decl.constraint.key?("target")
  end

  test "ficsit() defaults the materialization target to the Windows game build" do
    When "defining a ficsit dep with no target"
    config = Dev::Deps.define do
      group :app do
        ficsit "SML", version: "^3.12.0"
      end
    end

    Then
    config.declarations[0].materialization["target"] == "Windows"
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
    decl.scope.group == :integration
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
    sml.map { |d| d.scope.group }.sort == [:app, :integration]
  end

  test "group host: stamps the host onto every declaration in the group" do
    When "defining a darwin-gated group"
    config = Dev::Deps.define do
      group :editor, host: :darwin do
        gh "UnrealEngineMac",
          github: "d3mlabs/unreal-engine",
          tag: "5.8.0-mac-editor-1",
          assets: "UnrealEngine-Editor-Mac.tar.zst.*",
          install_dir: "~/.dev/engines/ue5-mac"
        xcode "26.1.1"
      end
    end

    Then "every member carries the group's host"
    config.declarations.size == 2
    config.declarations.all? { |d| d.scope.host == :darwin }
    config.declarations.all? { |d| d.constraint["host"].nil? }
  end

  test "per-declaration host: overrides the group and stays out of the constraint" do
    When "declaring a host-gated dep inside an ungated group"
    config = Dev::Deps.define do
      group :game do
        gh "UnrealEngine",
          github: "d3mlabs/unreal-engine",
          tag: "5.8.0-wine-7",
          assets: "UnrealEngine-Wine-Editor-Linux.tar.zst.*",
          install_dir: "~/.dev/engines/ue5",
          host: :linux
      end
    end

    Then "the declaration carries the host as a first-class field only"
    decl = config.declarations[0]
    decl.scope.host == :linux
    decl.constraint["host"].nil?
  end

  test "xcode() declares a pinned xcode toolchain dep as a revision" do
    When "pinning the Xcode toolchain"
    config = Dev::Deps.define do
      group :build do
        xcode "26.1.1"
      end
    end

    Then "the declaration rides the :xcode integration; the exact version is an address"
    decl = config.declarations[0]
    decl.name == "xcode"
    decl.integration == :xcode
    decl.revision == "26.1.1"
    decl.constraint == {}
    decl.scope.group == :build
  end

  test "xcode() rejects a blank version — the exact version is the whole ask" do
    When "pinning nothing"
    Dev::Deps.define do
      group :build do
        xcode "  "
      end
    end

    Then
    raises ArgumentError
  end

  test "env block stamps env as a first-class field, not a constraint key" do
    When "declaring a ci-scoped brew dep"
    config = Dev::Deps.define do
      group :build, host: :linux do
        env :ci do
          brew "ruby"
        end
      end
    end

    Then "env and the enclosing group's host both land as fields"
    decl = config.declarations[0]
    decl.scope.env == "ci"
    decl.scope.host == :linux
    decl.constraint["env"].nil?
  end

  test "gh() produces ScopedDeclaration named after the repo basename" do
    When "defining a gh release dep"
    config = Dev::Deps.define do
      group :build do
        gh "satisfactorymodding/UnrealEngine",
          tag: "5.6.1-css-83",
          assets: "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
          install_dir: "~/.dev/engines/unreal-engine-css"
      end
    end

    Then "slug is source, tag is the constraint, the rest is materialization"
    decl = config.declarations[0]
    decl.name == "UnrealEngine"
    decl.integration == :gh
    decl.scope.group == :build
    decl.source == "satisfactorymodding/UnrealEngine"
    decl.constraint == { "tag" => "5.6.1-css-83" }
    decl.materialization["asset_pattern"] == "UnrealEngine-CSS-Editor-Linux.tar.zst.*"
    decl.materialization["install_dir"] == "~/.dev/engines/unreal-engine-css"
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
    decl.scope.group == :game
    decl.source == "EpicGames/UnrealEngine"
    decl.constraint == { "tag" => "5.6.1-release" }
    decl.materialization["build"] == "bin/build-ue.sh"
    decl.materialization["install_dir"] == "~/.dev/engines/ue5"
    !decl.materialization.key?("asset_pattern")
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
    config.declarations[0].materialization["build"] == "none"
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

  test "steam() produces a ScopedDeclaration with steam integration" do
    When "defining a steam dep in a LinuxServer group"
    config = Dev::Deps.define do
      group :integration, platform: "LinuxServer" do
        steam "SatisfactoryServer", app: 1690800, install_dir: "~/.dev/satisfactory-server"
      end
    end

    Then "app id is source, branch is the constraint, install dir + platform materialize"
    decl = config.declarations[0]
    decl.name == "SatisfactoryServer"
    decl.integration == :steam
    decl.scope.group == :integration
    decl.platform == "LinuxServer"
    decl.source == "1690800"
    decl.constraint == { "branch" => "public" }
    decl.materialization["install_dir"] == "~/.dev/satisfactory-server"
    decl.materialization["platform"] == "LinuxServer"
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

  test "cmake commit: is an address — full SHA to the revision slot, constraint stays empty" do
    When "pinning a commit"
    config = Dev::Deps.define do
      group :app do
        cmake "opencell", github: "d3mlabs/opencell",
          commit: "ee3042f8b0279856061f91069a487e4ed6f69475"
      end
    end

    Then
    decl = config.declarations[0]
    decl.revision == "ee3042f8b0279856061f91069a487e4ed6f69475"
    decl.constraint == {}
  end

  test "cmake rejects a short commit — no more silent resolve-as-tag fallthrough" do
    When "pinning an abbreviated SHA"
    Dev::Deps.define do
      group :app do
        cmake "opencell", github: "d3mlabs/opencell", commit: "ee3042f8b027"
      end
    end

    Then
    raises Dev::Deps::GroupDSL::InvalidRevisionError
  end

  test "cmake rejects a git dep naming no ref at all" do
    When "declaring with neither tag:, branch:, nor commit:"
    Dev::Deps.define do
      group :app do
        cmake "boost", github: "boostorg/boost"
      end
    end

    Then "an unconstrained git universe would pin an arbitrary ref"
    raises Dev::Deps::GroupDSL::MissingRefError
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
    config.declarations[0].scope.group == :app
    config.declarations[1].scope.group == :test
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
    config.declarations[0].scope.group == :deploy
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
