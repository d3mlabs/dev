---
name: shared-prefix-reads-never-write
description: >-
  MUST be used when dev shells out to brew, gem, bundler or any tool whose
  default run can write into the Homebrew prefix — a query, a bootstrap
  check, an install — or when diagnosing a `Permission denied` under
  `$(brew --prefix)` from a uid that does not own it.
---

# On a shared brew prefix, the only write is the escalated install

dev runs as uids that do not own the brew prefix: the hidden agent user on
a cooperative Mac, a runner service user, a second developer. The one
prefix write dev performs is the install itself, through
`BrewIntegration#brew_write` (escalated to the stat'd owner with `sudo -n`);
every other spawn must be asked in a mode that writes nothing to the prefix.
A tool's *default* run is not a read: brew's starts with an implicit
auto-update that takes a lock under `var/homebrew/locks`, and `gem install`
lands in whatever `GEM_HOME` shadowenv set — the operator's Cellar.

Wrong:

```ruby
Open3.capture3("brew", "info", "--json=v1", name)   # auto-updates first: lock is owner-only
Open3.capture3("gem", "install", "bundler")         # writes the Cellar's gem dir
```

Right:

```ruby
Open3.capture3(BrewRepository::READ_ENV, "brew", "info", "--json=v1", name)  # HOMEBREW_NO_AUTO_UPDATE=1
brew_write(["install", spec])   # the one seam that writes; it escalates
```

learned-from: [dev#372](https://github.com/d3mlabs/dev/issues/372)
(`brew tap-info`/`info` died on the auto-update lock as `ai-agent`), after
[dev#361](https://github.com/d3mlabs/dev/issues/361) (escalated writes) and
the dev#289 note (another owner's `brew.env` is left alone); the same pass
found `lib/ensure_bundler.rb` trying `gem install bundler` into the Cellar.
date: 2026-11-01
