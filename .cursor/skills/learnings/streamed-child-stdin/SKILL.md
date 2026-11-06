---
name: streamed-child-stdin
description: >-
  MUST be used when dev spawns a child on its own stdout/stderr for the
  operator to watch (`gh run watch`, a long-running tool), or when a
  test suite that spawns a stub executable hangs with no output.
---

# A streamed child gets no stdin unless it reads one

A child spawned with dev's stdio inherited (`Process.spawn` without
`:in`) also inherits dev's **stdin**. Nothing dev streams asks a
question, so the terminal is the child's for output only: pass
`in: File::NULL`. A child left attached to stdin blocks on the first
read — invisible in production (the terminal just waits), fatal in the
suite: a stub executable that `cat`s stdin (the natural shape for a
stub that also records what `capture` piped it) never returns, and the
whole `dev test` hangs with no failing test to point at.

Wrong — inherited stdin, stub blocks the suite:

    pid = Process.spawn("gh", *argv, chdir: root)      # stdin is dev's
    # test stub: cat > "$dir/stdin"  → waits forever on the runner's tty

Right (Lifecycle::Gh#stream):

    pid = Process.spawn("gh", *argv, chdir: root, in: File::NULL)
    # the stub's cat reads EOF at once; the test asserts stdin == ""

Diagnostic signature: a full suite that "runs" for minutes past its
usual time with no progress ticks after a given test file, and a
`cat`/`read` child in `pgrep`. A child that *must* read (a prompt) gets
stdin on purpose, named at the spawn site.

learned-from: dev#420 build pass (`Gh#stream` for `gh run watch`; the
gh_test stub hung the suite for ten minutes before the cause showed)
date: 2026-11-06
