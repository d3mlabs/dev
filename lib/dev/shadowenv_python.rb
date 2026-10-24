# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "dev/shadowenv_file"

module Dev
  # The language-specific half of a locked Python's activation in the
  # project shadowenv: the project-local .venv built on the installed keg,
  # and .shadowenv.d/540_python.lisp so the venv's bin is first on PATH and
  # VIRTUAL_ENV points at it for every dev command.
  #
  # Nothing here installs a Python. The interpreter is a `python` pin in
  # dependencies.rb — homebrew/core's `python@<minor>`, locked and installed
  # through brew like any formula — and the brew integration calls activate!
  # once the keg is installed and its bin is on the project PATH. This
  # module owns the (empty) venv; the package set is installed into it by
  # Dev::Deps::PipIntegration, exactly as LuaRocks fills lua_modules/.
  module ShadowenvPython
    extend T::Sig
    include Kernel

    # The venv could not be built on the keg, or pip not bootstrapped in it.
    class VenvError < StandardError; end

    LISP_FILENAME = "540_python.lisp"
    VENV_DIR = ".venv"

    module_function

    # Activate one installed Python in the project shadowenv: the project
    # `.venv` is built on the keg's interpreter — rebuilt when an existing
    # venv was built on another one, so the venv always runs the locked
    # Python — pip is made importable, and the lisp (placed for this side of
    # the build container by ShadowenvFile) puts the venv first on PATH.
    #
    # @param keg [Pathname] the installed Python's prefix (brew's keg)
    # @param version [String] the version the lock pins
    # @param project_root [Pathname]
    # @return [void]
    # @raise [VenvError] if the venv cannot be created or pip bootstrapped
    sig { params(keg: Pathname, version: String, project_root: Pathname).void }
    def activate!(keg:, version:, project_root:)
      venv = project_root / VENV_DIR
      FileUtils.rm_rf(venv) if venv.exist? && !venv_built_on?(venv, keg)
      venv_python = venv / "bin" / "python"
      unless venv_python.executable?
        python = keg_python(keg, version)
        raise VenvError, "#{python} -m venv #{venv} failed" unless Kernel.system(python.to_s, "-m", "venv", venv.to_s)
      end
      ensure_pip!(venv_python.to_s)

      ShadowenvFile.write!(project_root:, filename: LISP_FILENAME, body: generate_python_lisp(version, venv.to_s))
    end

    # The keg's interpreter. brew's `python@X.Y` keg ships `bin/pythonX.Y`
    # only: the bare `python3` lives in `libexec/bin` and in the opt link,
    # neither of which is the keg the lock installed.
    #
    # @param keg [Pathname]
    # @param version [String] the locked version, e.g. "3.12.15"
    # @return [Pathname]
    sig { params(keg: Pathname, version: String).returns(Pathname) }
    def keg_python(keg, version)
      keg / "bin" / "python#{version.split(".").first(2).join(".")}"
    end

    # Whether a venv was built on the given keg: a venv's pyvenv.cfg records
    # the interpreter's bin directory as `home`.
    #
    # @param venv [Pathname]
    # @param keg [Pathname]
    # @return [Boolean]
    sig { params(venv: Pathname, keg: Pathname).returns(T::Boolean) }
    def venv_built_on?(venv, keg)
      cfg = venv / "pyvenv.cfg"
      return false unless cfg.file?

      home = cfg.read[/^home\s*=\s*(.+)$/, 1]&.strip
      !home.nil? && Pathname(home).cleanpath == (keg / "bin").cleanpath
    end

    # Guarantee pip is importable inside the venv. `python -m venv` normally seeds
    # pip via ensurepip, but some Homebrew interpreters produce a venv without it;
    # bootstrap it so package installs (PipIntegration) don't fail on a bare venv.
    #
    # @param venv_python [String] path to the venv's python
    # @raise [VenvError] if pip cannot be made available
    sig { params(venv_python: String).void }
    def ensure_pip!(venv_python)
      return if system(venv_python, "-m", "pip", "--version", out: File::NULL, err: File::NULL)

      raise VenvError, "could not bootstrap pip in the venv" unless Kernel.system(venv_python, "-m", "ensurepip", "--upgrade")
    end

    # Generate the shadowenv lisp that activates the project venv: VIRTUAL_ENV set,
    # its bin prepended to PATH, and PYTHONHOME cleared (a stray PYTHONHOME makes a
    # venv resolve the wrong stdlib). Mirrors what a venv's activate script does.
    #
    # The venv path is baked in as an absolute literal (shadowenv exposes no
    # reliable project-dir variable — SHADOWENV_PROJECT_DIR reads empty, and an
    # empty path-concat panics the loader), matching how ShadowenvRuby bakes
    # the absolute keg root.
    #
    # @param python_version [String] e.g. "3.12"
    # @param venv_path      [String] absolute path to the project venv
    # @return [String] lisp source
    sig { params(python_version: String, venv_path: String).returns(String) }
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
  end
end
