---
name: per-side-project-state
description: >-
  MUST be used when dev writes anything into the project tree during an
  install or activation (a lisp, a venv, a module tree), or when diagnosing
  a `dev up` that rebuilds something on every pass on a Mac with a build
  container.
---

# Project-tree state is per side of the build container

The checkout is bind-mounted into the build container, so one path in the
project tree is seen by two build hosts whose prefixes, interpreters and
OS/arch differ. Anything dev generates there that binds one of those — a
lisp with absolute paths, a venv (`bin/python` is one interpreter, wheels
one platform), a native module tree — gets one path per side, decided
from `Dev::ContainerContext.inside?` in exactly one place that the writer
and every reader resolve through.

Wrong — one path for both sides, kept right by an honest freshness check,
so each side's `dev up` finds the other's venv and rebuilds, every pass:

    venv = project_root / ".venv"
    FileUtils.rm_rf(venv) unless venv_built_on?(venv, keg, version)

Right — the side decides the path, in one function; the lisp follows:

    def venv_path(project_root, inside: ContainerContext.inside?)
      project_root / (inside ? CONTAINER_VENV_DIR : HOST_VENV_DIR)
    end

`ShadowenvFile` is the same rule for lisps (`510_ruby_container.lisp`
beside `510_ruby.lisp`). A new project-tree artifact asks: does its content
depend on the side? If yes, split it and name both paths in
docs/deps-channels.md ("What the checkout carries"); once a per-project
key under the data root exists (dev#294), prefer the data root.

learned-from: dev#379 (the venv flip-flop dev#376's honest check exposed);
`ContainerRuby` → `ShadowenvFile` had solved the same shape for lisps.
date: 2026-11-01
