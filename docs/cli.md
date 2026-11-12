# CLI conventions

How dev finds a command, parses its flags, and reports errors.

## Finding the project

dev walks up from the current directory to the enclosing git repo root and
reads the `dev.yml` there. Builtins marked *anywhere* below run without one.

## The command tree

`dev` is the root of a tree. Any command may have subcommands: `dev deps
update`, `dev runner status`, a project's `dev test unit`. Resolution reads
argv one word at a time: a word naming a child descends; the first word that
does not is where the command's arguments begin.

A command with nothing of its own to run prints its usage when invoked bare,
so `dev` lists everything, `dev deps` lists its verbs, and `dev help <path>`
prints the same view for any node. Listings mark commands with children by
a trailing `…`.

A project may declare a command on a builtin's name. `run:` on a builtin
(`up:` is the usual case) runs after the builtin's own body. Subcommands
merge child by child: new children are added, same-named children replace
the builtin's.

## Flags

Every builtin and group declares its flags and follows the `gh` convention:

- `-h` or `--help` anywhere in a builtin's arguments prints that node's
  usage and does nothing else. `dev container up --help` is `dev help
  container up`.
- A `-`-prefixed word the node does not declare is a usage error: the
  message, the node's usage on stderr, exit 2.
- `--` ends flag parsing; everything after it is positional.
- A value flag takes the next word (`--labels x`) or an inline value
  (`--keep=3`). A value flag with nothing after it, or a switch given a
  value, is a usage error.

**Project commands have no flag vocabulary.** Their argv is forwarded
verbatim, `--help` and `--` included; the script owns its flags. A project
`run:` on a builtin's name owns that slot's argv the same way.

## Scope

Each builtin runs in one of three scopes:

- **anywhere** — no `dev.yml` needed: `cd`, `clone`, `config`, `cred`,
  `plan`, `learnings`, `skills`, `runner`, `engine`, `version`, `help`, and
  `up` (host layer only).
- **project** — needs a `dev.yml`: `deps`, `cache gc`.
- **gated** — exists only when the project declares what it acts on:
  `build` and `package` need `targets:`; `deploy` needs a channel; `release`
  needs `commands: release:`; `down` and `container` need an `image` pin
  in the lock.

## Builtins

| Command | Purpose |
|---|---|
| `dev up [--no-cache]` | Converge host tooling, install the lock, bring the build container up, run the project's `up:`. `--no-cache` provisions from an empty data root to prove the cold path works. |
| `dev down` | Stop this checkout's containers; stop the engine if nothing else uses it. |
| `dev deps update [<name>…] [--all]` | Resolve `dependencies.rb` and write `deps.lock`, keeping pins whose declaration did not change. |
| `dev deps install [--group G] [--except G] [--integration I] [--pinned-taps]` | Install the lock on this machine. |
| `dev deps check` | Exit non-zero when the manifest, lock, or installed state disagree. |
| `dev deps path <integration> <name> [<platform>]` | Print a locked artifact's path. |
| `dev build [BUILD] [--target T] [--platform P] [--config C]` | Build one target's install. |
| `dev package [BUILD] [--no-build] [--fetch]` | Build, then archive and stamp the artifact. |
| `dev deploy <channel> [BUILD] [--release V] [--config C] [--allow-stale] [--force] [--dry-run]` | Ship artifacts to a channel. |
| `dev deploy --release V` | Ship a release to every channel. |
| `dev deploy status [--release V]` | What each channel carries. |
| `dev release [<version>\|major\|minor\|patch] [--yes]` | Tag, push, package and attach archives to a GitHub release. |
| `dev cd <repo>` | Jump to a checkout by fuzzy name. |
| `dev clone [<org>/]<repo>` | Clone into the canonical path and land there. |
| `dev config list\|get <key>\|set <key> <value>` | Settings. |
| `dev cred get <namespace> <key>` | Resolve a credential and print it. |
| `dev engine up\|down [--force]\|status` | The per-user container engine. |
| `dev container up\|down\|reset\|tag\|status` | This checkout's images and containers. |
| `dev runner register\|status\|unregister` | Self-hosted runner enrollment. |
| `dev plan new\|link\|pull\|push\|status\|init` | Plans as GitHub issues. |
| `dev learnings sync\|status\|invariants\|init` | Org learnings read path. |
| `dev skills status [--json]\|sync` | Agent skill links. |
| `dev cache gc [--keep N] [--tool-caches]` | Reclaim caches. |
| `dev version` | Print the version. |
| `dev help [<path>…]` | Usage for any node. |

## Errors

| Situation | Message |
|---|---|
| No git repo above the current directory | `dev: no git repo (with dev.yml) found above <path>` |
| Git repo without `dev.yml`, command needs one | `dev: found git repo at <path> but no dev.yml there` |
| Unknown command | `dev: Command '<name>' not found`, with the full path for a subcommand (`'deps bogus'`) and a pointer to `dev --help` |
| Unknown flag | `dev: unknown flag '<flag>' for 'dev <path>'`, then usage, exit 2 |
| Value flag without a value | `flag '<flag>' needs a value`, exit 2 |
| Switch given a value | `flag '<flag>' takes no value`, exit 2 |

## Staleness check

Every command starts with two cheap checks: `dependencies.rb` against
`deps.lock`, and `deps.lock` against what this machine last installed. A
mismatch is a warning on a workstation and an error in CI. `dev deps check`
runs the same checks on demand; `dev deps path` is exempt.
