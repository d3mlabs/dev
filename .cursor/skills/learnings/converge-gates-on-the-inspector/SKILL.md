---
name: converge-gates-on-the-inspector
description: >-
  MUST be used when adding or changing a register / `dev up` converge
  step that has a `dev runner status` inspector (`cooperative_dir?`,
  `brew_locks_cooperative?`, the sudoers content compare), when a command
  prints a summary over a step that may skip, or when register's ✓ is
  followed by status's ✗ on the same fact.
---

# A converge step gates on its inspector; a summary reads what was skipped

A host fact has one reader — the inspection method `dev runner status`
calls — and the step that converges it is gated on that same method and
mutates everything it reads, never a proxy (one group name, a mode
"provisioned already"). A verb that may skip (a layer another identity
owns) returns what it did, and the one summary that sums the layer up
reads that result; a `void` return under a "converged" line lies on the
next skip.

Wrong — a proxy gate and a mode never read; register ✓, status ✗:

    return unless group_of(path) == LEGACY_GROUP   # inspector reads group AND setgid
    step!("sudo", "chgrp", "-Rh", DataRoot::GROUP, path)  # "modes untouched"
    @host_service.converge_tooling                 # void; skipped for runner's prefix
    puts "dev: host layer converged."              # read as "dev upgraded"

Right — the inspector gates, the grant covers what it reads, the skip
comes back as a fact:

    return if cooperative_dir?(@data_root)         # what status reads
    step!(chgrp -Rh …); step!(chmod -R g+rwX …); step!(find -type d chmod g+s …)
    tooling = @host_service.converge_tooling       # ToolingOutcome: converged / skipped for <owner>
    puts host_layer_summary(tooling)

The lock dir (dev#558) and the sudoers drop-in (dev#569) already had this
shape; the data root was written from an assumption instead of a read.

learned-from: dev#622 (the Mac's `drwxrwxr-x` root after a 0.8.11
register; a projectless `dev up` reading "converged" with `dev --version`
unchanged), with dev#558 and dev#569 as the steps that had it right.
date: 2026-11-16
