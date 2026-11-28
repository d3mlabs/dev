---
name: shared-store-modes-follow-the-writer
description: MUST be used when a dev step spawns a tool that writes into the data root (a builder, `cp -a`/`rsync -a`/`tar -p` of a fetched tree, a packager vendoring into the stage, a publisher's scratch), or when a step removes a tree in the store before writing it.
---

# In the shared store, modes follow the writer — so the writer shares, and removal is loud

The data root is one tree two users write through the `dev` group. dev's
`002` umask (SharedUmask) covers only what dev's own process creates; a
tool dev spawns writes under its own rules — `cp -a` keeps its source's
modes, a toolchain its umask, a root-run container its uid — and only the
owner can change a mode. So the step that spawned the tool opens what it
wrote to the group (dirs `g+rwxs`, files `g+rw`) before it returns, and a
tree the step must replace is removed with a raising primitive (`rm_r`),
the failure a typed error naming the blocking directory's owner and mode —
never `rm_rf`, whose swallowed error surfaces as the next user's hundreds
of `Permission denied` far from the cause.

```ruby
# WRONG: the umask is assumed to cover the child, and the removal is forced
FileUtils.rm_rf(stage)        # EACCES swallowed; mkpath sees the old tree
stage.mkpath
fill(build, stage)            # on top of another user's 755 tree

# RIGHT: raise on the removal, share as the writer after the child
empty(stage)                  # rm_r → StageNotEmptiedError: "<dir> is owned by runner (mode 2755) and not writable by <user>"
stage.mkpath
fill(build, stage)
share(stage)                  # every entry this user owns: dirs | 0o2070, files | 0o060; symlinks and others' entries left
```

The second user cannot repair the tree (not the owner), so a repair-on-
read never works; the only place the rule can hold is the writer's step.
The same shape produced `LinuxDataRootProvisioner.share_tree_argv` (a root
converged on `dev up`), JobIdentity's `chmod -R g+rwX` on `_work`, and
HostLock's `chmod 2775` on the locks dir: each is one writer sharing what
it placed.

learned-from: dev#745 — the runner user's stage (`cp -a`, `755`) blocked the interactive user's `dev release`; `rm_rf` hid it and the builder failed on `cp` into the stale tree.
date: 2026-11-28
