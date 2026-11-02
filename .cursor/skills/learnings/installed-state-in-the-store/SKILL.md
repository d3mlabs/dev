---
name: installed-state-in-the-store
description: >-
  MUST be used when an integration or activation materializes something a
  consumer reads from the project tree (a source, a venv, a module tree),
  or when a warm hosted run re-fetches or rebuilds a dependency every pass.
---

# Installed state lives in the store; the checkout holds a link

A hosted job's `actions/checkout` (`clean: true`) wipes the project tree
every run while the checkpoint keeps the data root warm, and two worktrees
of one project are one project. Anything dev installs therefore lives in
the store under an identity key — presence is proof (ADR-0009) — and the
checkout reaches it through a symlink at the path consumers expect, or an
absolute path in the activation lisp. Per-project state is keyed by the
project's package identity (dev.yml `name`, `ProjectContext#name`,
threaded as `Registry.host_integrations(project_name:)`), never by the
checkout path. A path-bound artifact (a venv: shebangs, `pyvenv.cfg`) is
built in place (`ArtifactStore#build_tree`) and every tool runs it by its
store path, not the link — Python writes `sys.executable` as invoked.

Wrong — fetched into the checkout, re-fetched after every clean, once per
worktree:

    dest = @project_root / "build/_deps" / "#{dep.name}-src"
    fetch_git(dep, dest) unless populated?(dest)

Right — the store owns it, the checkout links at it:

    tree = store!.tree(key) || publish_source(dep)
    link_source(@project_root / "build/_deps" / "#{dep.name}-src", tree)

A populated plain directory at the link's path, from before the move, is
kept as it was. The symptom is a fixed gap in a warm bootstrap's spawn
trace (dev#377's `HEAD is now at` lines, dev#399's brew→bundler gap).

learned-from: dev#377 (cmake sources under `build/_deps`), dev#399 (the
venvs under `.venv` / `.venv-container`) — the same shape, twice.
date: 2026-11-02
