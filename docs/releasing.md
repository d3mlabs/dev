# Releasing dev

dev releases itself through its own lifecycle. [`dev.yml`](../dev.yml)
declares two targets and one channel:

| Target | Contents | Formula |
|---|---|---|
| `dev-core` | `bin`, `lib`, `share`, `VERSION`, `LICENSE`, `README.md` | `d3mlabs/d3mlabs/dev-core` |
| `dev` | `deploy/d3mlabs/config.yml` and `Brewfile`, with `README.md` and `LICENSE` | `d3mlabs/d3mlabs/dev` |

Both are published through the tap at
[d3mlabs/homebrew-d3mlabs](https://github.com/d3mlabs/homebrew-d3mlabs),
one formula per target.

## Cut and ship

```bash
dev release                       # 0.8.0 → 0.8.1; `dev release minor`, `dev release 1.0.0` likewise
dev deploy brew --release 0.8.1   # point both formulas at the release's assets
```

`dev release` shows the plan (branch, commit, commits since the last tag,
drift from `origin`) and asks to proceed (`--yes` skips). It bumps
`VERSION` and the `Gemfile.lock` line that mirrors it, commits, tags
`v<version>`, pushes, packages both targets at the tag, and attaches
`dev-core-<version>.zip`, `dev-<version>.zip` and `release.json` to the
GitHub release. Nothing is deployed.

A run that failed after the tag was pushed is finished by running it
again: a tag already on `HEAD` resumes at the push, and the GitHub release
is created only if missing.

`dev deploy brew --release <version>` clones the tap into a scratch under
the data root, rewrites each formula's `url` and `sha256` from
`release.json`, commits and pushes. Formula bodies — dependencies, the
install block, caveats — stay hand-authored in the tap. Releases only: a
formula points at a release asset, never at a store file.

## Verify

```bash
brew update
brew upgrade d3mlabs/d3mlabs/dev
dev --help
```

The full verb reference is [Lifecycle](lifecycle.md).
