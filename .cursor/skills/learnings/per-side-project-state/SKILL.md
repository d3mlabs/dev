---
name: per-side-project-state
description: >-
  MUST be used when dev writes anything into the project tree during an
  install or activation (a lisp, a venv, a module tree), or when diagnosing
  a `dev up` that rebuilds something on every pass on a Mac with a build
  container.
---

# Project-tree state is per side of the build container

The container works on its own checkout — a snapshot it fetched into a
workspace under its data root (dev#421), never a bind mount of the host's
tree — so the two sides share a tree only through what the snapshot
carries: every file `.gitignore` does not exclude. Anything dev generates
in the tree that binds one side's prefix, interpreter or OS/arch stays per
side exactly when it is ignored (it survives each snapshot's `git reset
--hard` + `git clean -fd`); anything else travels in the next snapshot and
lands on the other side, bound to the wrong machine.

Wrong — a venv at an un-ignored path rides the snapshot, so the container's
`dev up` finds a Mac venv and rebuilds, every pass:

    venv = project_root / "venv"   # not in .gitignore
    FileUtils.rm_rf(venv) unless venv_built_on?(venv, keg, version)

Right — installed state lives in the store under the project's key with
the side in the key (`~/.dev/venv/<name>/<side>/<keg>`, dev#399), and
only an ignored link or lisp stays in the tree:

    def venv_path(project_root, inside: ContainerContext.inside?)
      project_root / (inside ? CONTAINER_VENV_DIR : HOST_VENV_DIR)   # both ignored
    end

A new project-tree artifact asks: is it installed state? Then the store.
Does what stays in the tree depend on the side? Then it must be ignored,
and docs/deps-channels.md ("What the checkout carries") names it.

learned-from: dev#379 (the venv flip-flop dev#376 exposed); dev#399 (venv in the store); dev#421 (bind mount removed: the snapshot is the only shared path).
date: 2026-11-07
