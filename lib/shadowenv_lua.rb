# frozen_string_literal: true

require "fileutils"

# Shadowenv Lua provisioning: generates .shadowenv.d/510_lua.lisp so that
# lua, luarocks, and project-local lua_modules are in PATH / LUA_PATH / LUA_CPATH.
#
# Mirrors ShadowenvRuby. Triggered when dev.yml declares `lua: "5.1"`.
module ShadowenvLua
  class BrewInstallError < StandardError; end

  LISP_FILENAME = "510_lua.lisp"

  module_function

  # Fast-path check: does .shadowenv.d/510_lua.lisp exist and provision
  # the correct Lua version?
  #
  # @param lua_version  [String]   e.g. "5.1"
  # @param project_root [Pathname, String] project root directory
  # @return [Boolean]
  def provisioned?(lua_version, project_root:)
    lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
    return false unless File.exist?(lisp_path)

    content = File.read(lisp_path)
    content.include?(%(provide "lua" "#{lua_version}"))
  end

  # Full provisioning: write .shadowenv.d/510_lua.lisp, trust shadowenv.
  #
  # @param lua_version  [String]   e.g. "5.1"
  # @param project_root [Pathname, String] project root directory
  # @return [true]
  # @raise [BrewInstallError] if Homebrew lua or luarocks cannot be installed
  def setup!(lua_version:, project_root:)
    ensure_homebrew_lua!(lua_version)

    shadowenv_d = File.join(project_root.to_s, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    lisp_path = File.join(shadowenv_d, LISP_FILENAME)
    File.write(lisp_path, generate_lua_lisp(lua_version))

    Dir.chdir(project_root.to_s) do
      Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL)
    end

    true
  end

  # Generate the shadowenv lisp for Lua environment isolation.
  #
  # @param lua_version [String] e.g. "5.1"
  # @return [String] lisp source
  def generate_lua_lisp(lua_version)
    lua_formula = "lua@#{lua_version}"
    <<~LISP
      (provide "lua" "#{lua_version}")

      (when-let ((lua-root (env/get "LUA_ROOT")))
        (env/remove-from-pathlist "PATH" (path-concat lua-root "bin")))

      (env/set "LUA_ROOT" "/opt/homebrew/opt/#{lua_formula}")
      (env/prepend-to-pathlist "PATH" "/opt/homebrew/opt/#{lua_formula}/bin")
      (env/prepend-to-pathlist "PATH" "/opt/homebrew/opt/luarocks/bin")

      (let ((modules (path-concat (env/get "SHADOWENV_PROJECT_DIR") "lua_modules")))
        (env/set "LUA_PATH"
          (string-append
            (path-concat modules "share/lua/#{lua_version}/?.lua") ";"
            (path-concat modules "share/lua/#{lua_version}/?/init.lua") ";"
            "./?.lua;./?/init.lua;;"))
        (env/set "LUA_CPATH"
          (string-append
            (path-concat modules "lib/lua/#{lua_version}/?.so") ";;")))
    LISP
  end

  # Ensure Homebrew lua and luarocks are installed.
  #
  # @param lua_version [String] e.g. "5.1"
  # @raise [BrewInstallError] if brew install fails
  def ensure_homebrew_lua!(lua_version)
    formula = "lua@#{lua_version}"
    unless Kernel.system("brew", "list", formula, out: File::NULL, err: File::NULL)
      $stderr.puts "dev: Installing #{formula} via Homebrew..."
      unless Kernel.system("brew", "install", formula)
        raise BrewInstallError, "brew install #{formula} failed"
      end
    end
    unless Kernel.system("brew", "list", "luarocks", out: File::NULL, err: File::NULL)
      $stderr.puts "dev: Installing luarocks via Homebrew..."
      unless Kernel.system("brew", "install", "luarocks")
        raise BrewInstallError, "brew install luarocks failed"
      end
    end
  end
end
