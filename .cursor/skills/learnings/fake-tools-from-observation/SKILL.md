---
name: fake-tools-from-observation
description: >-
  MUST be used when writing or amending a test fake of an external tool
  (a fake brew, python, gh, docker script) or the fixture that stands in
  for the tool's output — the fake must transcribe the real tool's observed
  behaviour, not the author's belief about it.
---

# Fakes of external tools are transcribed, not imagined

Probe the real tool once — on the dev machine, with the real inputs — and
write what it actually did into the fake (argv it accepts, files it lays
out, symlinks it writes, what every recorded path points at), naming the
probe in the fixture's comment. When the real tool is at hand, run the
change against it once too and record the result in the PR or ADR note.

A fake written from belief verifies the belief, so the suite stays green
while the host runs something else: dev#353's thirteen fake-brew tests
passed `brew install <bottle file>`, an argv Homebrew ≥ 4 refuses
(dev#356); dev#376's fake Python wrote a venv whose `bin/python` was a
plain file, so no test could see that a real venv's interpreter is a
symlink through brew's opt link to whichever keg is current (dev#378).

```ruby
# WRONG: the fake materializes the venv the author pictured
"printf '#!/bin/sh\\nexit 0\\n' > \"$3/bin/python\""

# RIGHT: the fake lays out what `python -m venv` wrote when probed on a
# brew Python — python3.12 -> <opt>/bin/python3.12; python, python3 -> python3.12;
# home = <opt>/bin — so the test can assert what the venv's interpreter resolves to
"ln -s \"#{opt / "bin" / "python3.12"}\" \"$3/bin/python3.12\"",
"ln -s python3.12 \"$3/bin/python\"",
```

Why it stays a rule rather than a fix: CI has no second brew keg, no
framework Python and no Homebrew ≥ 4 refusal to test against, so the fakes
are what the suite runs; the probe is the only place the real shape enters.

learned-from: dev#378 (the venv ran brew's current keg through the opt
link; the dev#376 fixture could not show it), after dev#356 (fake brew
accepted an argv brew never does).
date: 2026-11-01
