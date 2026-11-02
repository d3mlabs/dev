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
    # `.venv` is built on the keg's interpreter and pinned to the keg —
    # rebuilt when an existing venv was built on another one, so the venv
    # always runs the locked Python — pip is made importable, and the lisp
    # (placed for this side of the build container by ShadowenvFile) puts
    # the venv first on PATH.
    #
    # @param keg [Pathname] the installed Python's prefix (brew's keg)
    # @param version [String] the version the lock pins
    # @param project_root [Pathname]
    # @return [void]
    # @raise [VenvError] if the venv cannot be created or pip bootstrapped
    sig { params(keg: Pathname, version: String, project_root: Pathname).void }
    def activate!(keg:, version:, project_root:)
      venv = project_root / VENV_DIR
      FileUtils.rm_rf(venv) if venv.exist? && !venv_built_on?(venv, keg, version)
      venv_python = venv / "bin" / "python"
      unless venv_python.executable?
        python = keg_python(keg, version)
        raise VenvError, "#{python} -m venv #{venv} failed" unless Kernel.system(python.to_s, "-m", "venv", venv.to_s)

        pin_venv_to_keg!(venv, python)
      end
      ensure_pip!(venv_python.to_s)

      ShadowenvFile.write!(project_root:, filename: LISP_FILENAME, body: generate_python_lisp(version, venv.to_s))
    end

    # Point a freshly built venv at the keg that built it. `python -m venv`
    # links the venv's interpreter to `sys._base_executable`, which a brew
    # Python derives from its configured prefix — `<prefix>/opt/<formula>/bin`,
    # brew's link to whichever keg is current — and records that bin as
    # pyvenv.cfg's `home`, where Python looks for its stdlib. Left so, a
    # `brew upgrade` moves every project venv off its lock without touching
    # it. Every interpreter name in the venv's bin becomes a symlink to the
    # keg's interpreter (the venv module's own layout chains `python` and
    # `python3` through `pythonX.Y`, but a copied venv does not, so all three
    # are repointed rather than trusting the chain), and `home` becomes the
    # keg's bin, so the venv runs the keg's binary on the keg's stdlib and
    # describes itself as built on it.
    #
    # @param venv [Pathname]
    # @param python [Pathname] the keg's interpreter, `<keg>/bin/pythonX.Y`
    # @return [void]
    sig { params(venv: Pathname, python: Pathname).void }
    def pin_venv_to_keg!(venv, python)
      ["python", "python3", python.basename.to_s].each do |name|
        FileUtils.ln_sf(python.to_s, (venv / "bin" / name).to_s)
      end
      cfg = venv / "pyvenv.cfg"
      cfg.write(cfg.read.sub(/^home\s*=.*$/, "home = #{python.dirname}"))
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

    # Whether a venv was built on the given keg: pyvenv.cfg records the
    # version of the Python that built it as `version` and, once
    # pin_venv_to_keg! has run, the keg's bin as `home`. The home tells this
    # prefix's keg from another's — the build container's Linuxbrew builds
    # the same version on the same mounted project — and a home through
    # brew's opt link is a venv from before dev pinned venvs to the keg,
    # running whichever keg brew has current: rebuilt once, like any other
    # interpreter's.
    #
    # @param venv [Pathname]
    # @param keg [Pathname] `<prefix>/Cellar/<formula>/<version>`
    # @param version [String] the version the lock pins
    # @return [Boolean]
    sig { params(venv: Pathname, keg: Pathname, version: String).returns(T::Boolean) }
    def venv_built_on?(venv, keg, version)
      cfg = venv / "pyvenv.cfg"
      return false unless cfg.file?

      contents = cfg.read
      built_by = contents[/^version\s*=\s*(.+)$/, 1]&.strip
      home = contents[/^home\s*=\s*(.+)$/, 1]&.strip
      return false unless built_by == version && home

      Pathname(home).cleanpath == (keg / "bin").cleanpath
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
