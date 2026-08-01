---
name: rbenv-libruby-rpath-hijack
description: >-
  MUST be used when diagnosing a Ruby version mismatch on Linux — bundler
  failing a Gemfile ruby pin, or `ruby -v` disagreeing with the resolved
  binstub — on a machine with both rbenv-built and Homebrew rubies.
---

# rbenv libruby hijacked by Homebrew via rpath

An rbenv-built Ruby whose binary carries a Homebrew lib dir in its rpath
ahead of its own libdir loads a same-minor Homebrew Ruby's libruby at
runtime (they share the soname `libruby.so.X.Y`), so the binary silently
runs as the other version. Bundler then fails the Gemfile ruby pin with a
mismatch that looks like a project bug — the real fault is the link, not
the project. Linux-only: macOS dyld links libruby by absolute install
name.

Diagnosis cue: `command -v ruby` resolves to the correct rbenv binstub,
but `ruby -v` reports a different version.

Wrong:

```sh
# bundler says: your Ruby version is 3.4.5, your Gemfile requires 3.4.2
# ...so edit the Gemfile pin, or rebuild the project's gems
```

Right:

```sh
command -v ruby        # right binstub?
ruby -v                # different version => linker hijack, not a pin bug
readelf -d "$(rbenv prefix)/bin/ruby" | grep -i rpath
# fix the rpath ordering (own libdir first) or rebuild the rbenv Ruby
# without the Homebrew lib dir in its rpath
```

learned-from: dev#75, root-causing cellbound-3d#151's CI ruby-pin failure.
date: 2026-08-01
