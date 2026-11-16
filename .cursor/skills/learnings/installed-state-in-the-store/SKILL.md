---
name: installed-state-in-the-store
description: >-
  MUST be used when an integration or activation materializes something a
  consumer reads from the project tree (a source, a venv, a module tree),
  points a tool's write location (GEM_HOME, a cache) at another tool's
  prefix, or when a warm hosted run re-fetches or rebuilds a dependency
  every pass.
---

# Installed state lives in the store; the checkout holds a link

A hosted job's checkout clean wipes the project tree every run while the
checkpoint keeps the data root warm, and two worktrees of one project are
one project. Anything dev installs therefore lives in the store under an
identity key — presence is proof (ADR-0009) — and the checkout reaches it
through a symlink at the path consumers expect, or an absolute path in the
activation lisp. Per-project state is keyed by the project's package
identity (dev.yml `name`, threaded as `project_name:`), never by the
checkout path. A path-bound artifact (a venv) is built in place
(`ArtifactStore#build_tree`) and every tool runs it by its store path, not
the link; state a tool converges every run (a gem home) is a `workdir`.

The other wrong home is another tool's prefix: a brew keg's gem dir is the
prefix owner's, so on a shared host every other user writes nothing there
(`Bundler::PermissionError`, dev#294) and one directory serves every
project on that Ruby. No declaration fixes who owns a keg.
Wrong — fetched into the checkout, re-fetched after every clean:

    dest = @project_root / "build/_deps" / "#{dep.name}-src"
    fetch_git(dep, dest) unless populated?(dest)

Right — the store owns it, the checkout links at it:

    tree = store!.tree(key) || publish_source(dep)
    link_source(@project_root / "build/_deps" / "#{dep.name}-src", tree)

learned-from: dev#377 (cmake sources under `build/_deps`), dev#399 (the
venvs under `.venv`), dev#294 (the gem home in the keg) — one shape, thrice.
date: 2026-11-16
