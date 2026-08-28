---
name: pre-bundle-stdlib-only
description: >-
  MUST be used when adding requires, Sorbet sigs, or new files to the deps
  bootstrap chain (dependencies.rb, lib/dev/deps.rb and its require_relative
  closure, lib/ensure_bundler.rb), or when raising a lib/ file's typed sigil.
---

# The pre-bundle bootstrap chain is stdlib-only — no sigs, no T.*

bin/setup.rb and bin/test.rb load `dependencies.rb` (→ `dev/deps` → config,
dsl, dependency_declaration, tap, cli_ui, lockfile, dependency, fetcher,
dependency_installer) and `ensure_bundler` BEFORE the bundle exists, so on a
fresh machine no gem — including sorbet-runtime — is loadable there. These
files cap at `typed: true`/`typed: false` (see the Sorbet/StrictSigil
exclusion list in .rubocop.yml): a `sig`, `extend T::Sig`, or `T.unsafe`
anywhere in the chain crashes first-time setup with a NameError on `T`.

Wrong:

```ruby
# lib/dev/deps/config.rb — pre-bundle file
require "sorbet-runtime"   # not installed yet on a fresh machine
extend T::Sig
```

Right:

```ruby
# lib/dev/deps/config.rb stays sig-free at `# typed: true`;
# files loaded only through the dev runtime (src/dev.rb requires
# sorbet-runtime first) may go `# typed: strict` with sigs.
```

learned-from: the typed-sigil enforcement pass (dev#139) — bringing lib/ to
`typed: strict` stopped at the bootstrap chain, whose stdlib-only comment in
dependencies.rb had not spelled out the Sorbet consequence.
date: 2026-08-28
