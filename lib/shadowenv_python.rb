# frozen_string_literal: true

require "fileutils"

# Shadowenv Python provisioning: installs the interpreter via Homebrew
# (python@<version>), creates a project-local .venv with it, and generates
# .shadowenv.d/540_python.lisp so the venv's bin is first on PATH and
# VIRTUAL_ENV points at it for every dev command.
#
# Mirrors ShadowenvRuby/ShadowenvLua. Triggered when dependencies.rb declares
# `python "3.12"`. This module owns only the interpreter + the (empty) venv;
# the package set is installed into that venv by Dev::Deps::PipIntegration on
# `dev install-deps`, exactly as LuaRocks fills lua_modules/.
module ShadowenvPython
  class BrewInstallError < StandardError; end

  LISP_FILENAME = "540_python.lisp"
  VENV_DIR = ".venv"

  module_function

  # Fast-path check: does .shadowenv.d/540_python.lisp provision this version
  # AND does the project venv still exist? The venv check means a deleted .venv
  # (or a fresh clone) re-triggers setup! rather than leaving a dangling PATH.
  #
  # @param python_version [String] e.g. "3.12"
  # @param project_root   [Pathname, String]
  # @return [Boolean]
  def provisioned?(python_version, project_root:)
    lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
    return false unless File.exist?(lisp_path)
    return false unless File.directory?(File.join(project_root.to_s, VENV_DIR))

    File.read(lisp_path).include?(%(provide "python" "#{python_version}"))
  end

  # Full provisioning: ensure the interpreter + venv exist, write the lisp,
  # trust shadowenv. Idempotent.
  #
  # @param python_version [String] e.g. "3.12"
  # @param project_root   [Pathname, String]
  # @return [true]
  def setup!(python_version:, project_root:)
    venv_path = ensure_venv!(python_version:, project_root:)

    shadowenv_d = File.join(project_root.to_s, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(File.join(shadowenv_d, LISP_FILENAME), generate_python_lisp(python_version, venv_path))

    Dir.chdir(project_root.to_s) do
      Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL)
    end
    true
  end

  # Ensure Homebrew python@<version> is installed and a project-local .venv
  # exists, built with that exact interpreter. Idempotent and safe to call from
  # both setup! (per command) and PipIntegration (install-deps), so the venv is
  # guaranteed present before packages install into it.
  #
  # @param python_version [String] e.g. "3.12"
  # @param project_root   [Pathname, String]
  # @return [String] absolute path to the venv
  # @raise [BrewInstallError] if the interpreter or venv cannot be created
  def ensure_venv!(python_version:, project_root:)
    python_bin = ensure_homebrew_python!(python_version)
    venv_path = File.join(project_root.to_s, VENV_DIR)
    venv_python = File.join(venv_path, "bin", "python")

    unless File.executable?(venv_python)
      raise BrewInstallError, "python -m venv #{venv_path} failed" unless Kernel.system(python_bin, "-m", "venv", venv_path)
    end

    ensure_pip!(venv_python)
    venv_path
  end

  # Guarantee pip is importable inside the venv. `python -m venv` normally seeds
  # pip via ensurepip, but some Homebrew interpreters produce a venv without it;
  # bootstrap it so package installs (PipIntegration) don't fail on a bare venv.
  #
  # @param venv_python [String] path to the venv's python
  # @raise [BrewInstallError] if pip cannot be made available
  def ensure_pip!(venv_python)
    return if system(venv_python, "-m", "pip", "--version", out: File::NULL, err: File::NULL)

    raise BrewInstallError, "could not bootstrap pip in the venv" unless Kernel.system(venv_python, "-m", "ensurepip", "--upgrade")
  end

  # Generate the shadowenv lisp that activates the project venv: VIRTUAL_ENV set,
  # its bin prepended to PATH, and PYTHONHOME cleared (a stray PYTHONHOME makes a
  # venv resolve the wrong stdlib). Mirrors what a venv's activate script does.
  #
  # The venv path is baked in as an absolute literal (shadowenv exposes no
  # reliable project-dir variable — SHADOWENV_PROJECT_DIR reads empty, and an
  # empty path-concat panics the loader), matching how ShadowenvRuby/Lua bake
  # their absolute Homebrew/rbenv roots.
  #
  # @param python_version [String] e.g. "3.12"
  # @param venv_path      [String] absolute path to the project venv
  # @return [String] lisp source
  def generate_python_lisp(python_version, venv_path)
    venv = File.expand_path(venv_path)
    <<~LISP
      (provide "python" "#{python_version}")

      (when-let ((old (env/get "VIRTUAL_ENV")))
        (env/remove-from-pathlist "PATH" (path-concat old "bin")))

      (env/set "PYTHONHOME" ())
      (env/set "VIRTUAL_ENV" "#{venv}")
      (env/prepend-to-pathlist "PATH" "#{File.join(venv, "bin")}")
    LISP
  end

  # Ensure brew python@<version> is present; return the path to its versioned
  # interpreter (e.g. .../bin/python3.12), falling back to the formula's python3.
  #
  # @param python_version [String] e.g. "3.12"
  # @return [String] absolute path to the python interpreter
  # @raise [BrewInstallError] if brew install fails or no interpreter is found
  def ensure_homebrew_python!(python_version)
    formula = "python@#{python_version}"
    unless Kernel.system("brew", "list", formula, out: File::NULL, err: File::NULL)
      $stderr.puts "dev: Installing #{formula} via Homebrew..."
      raise BrewInstallError, "brew install #{formula} failed" unless Kernel.system("brew", "install", formula)
    end

    prefix = brew_prefix_for(formula)
    raise BrewInstallError, "could not resolve Homebrew prefix for #{formula}" unless prefix

    versioned = File.join(prefix, "bin", "python#{python_version}")
    return versioned if File.executable?(versioned)

    fallback = File.join(prefix, "bin", "python3")
    return fallback if File.executable?(fallback)

    raise BrewInstallError, "no python interpreter found under #{prefix}"
  end

  # @param formula [String] Homebrew formula name
  # @return [String, nil] brew --prefix for the formula, or nil when unavailable
  def brew_prefix_for(formula)
    return nil unless system("command -v brew >/dev/null 2>&1")

    out = IO.popen(["brew", "--prefix", formula], err: File::NULL, &:read)
    prefix = out&.strip
    (prefix && !prefix.empty? && File.directory?(prefix)) ? prefix : nil
  end
end
