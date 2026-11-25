---
name: per-side-project-state
description: >-
  MUST be used when dev writes anything into the project tree during an
  install or activation (a lisp, a venv, a module tree), or when diagnosing
  a `dev up` that rebuilds something on every pass on a Mac with a container.
---

# Project-tree state is per side of the build container

The checkout is bind-mounted into the build container, so one path in the
project tree is seen by two build hosts whose prefixes, interpreters and
OS/arch differ. Anything dev generates there that binds one of those (a
lisp with absolute paths, a venv, a native module tree) gets one path per
side, decided from `Dev::ContainerContext.inside?` in exactly one place.

Wrong — one path for both sides; each side's `dev up` rebuilds the other's:

    venv = project_root / ".venv"
    FileUtils.rm_rf(venv) unless venv_built_on?(venv, keg, version)

Right — the side decides the path, in one function; the lisp follows:

    def venv_path(project_root, inside: ContainerContext.inside?)
      project_root / (inside ? CONTAINER_VENV_DIR : HOST_VENV_DIR)
    end

`ShadowenvFile` is the same rule for lisps. A new project-tree artifact
asks three questions. Installed state? It lives in the store under the
project's key with the side in it (`ShadowenvPython.venv_key`) and only a
link or the lisp stays in the tree. Does what stays depend on the side?
Split it. Does what stays name a path on this machine (every link and lisp
does)? It gets a `GITIGNORE_FOOTPRINT` beside its path constant, enrolled
in `Dev::Footprint::MANAGED_PATHS`, and a row in docs/gitignore.md: the
writer and checker know only what is enrolled, and the deps producers went
unenrolled until adopters committed `.shadowenv.d/`. A link's line is the
bare name — `name/` matches directories only, and a symlink is a file.

learned-from: dev#379 (the venv flip-flop); dev#399 (venv in the store); dev#714 (deps paths enrolled in the footprint).
date: 2026-11-25
