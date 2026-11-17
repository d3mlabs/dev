# CLI conventions

How dev finds a command, what its verbs mean, how it parses flags, and how
it reports errors.

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

## Command vocabulary

Builtins are nouns with verbs — `dev deps update`, `dev runner status`,
`dev plan push` — plus bare verbs at the root for the project lifecycle:
`up`, `down`, `build`, `package`, `deploy`, `release`. The shape is `gh`'s,
and so are the expectations it sets. Every builtin follows the rules below;
one that does not is a bug.

**A bare noun lists its verbs and does nothing.** `dev deps` and `dev runner`
print the verb list, the same view as `dev help deps`. Nothing a noun does
happens without a verb.

**A verb means the same thing under every noun.**

| Verb | Meaning |
|---|---|
| `status` | Reads and reports. Changes nothing. |
| `check` | A verdict for CI and scripts: exit 0 when the state is as declared, non-zero otherwise, with what disagrees printed. |
| `install`, `up` | Bring the machine to a state the project already recorded — the lock, the manifest. They read that record and resolve nothing. |
| `update` | Moves the record: re-resolves and writes it. |
| `register` / `unregister` | Enroll this host with, or retire it from, a remote. |
| `pull` / `push` | Copy the remote's version here, or this copy to the remote. |
| `link` | Attach a local file to a remote thing, creating the remote thing when none is named. |
| `new` / `init` | Create a remote thing, or scaffold local files. |
| `path`, `get`, `list` | Print a value and nothing else. |

A noun does not carry two verbs that answer the same question. `dev deps
check` is the verdict on the dependency state; there is no `dev deps status`
beside it.

**Queries are safe blind.** `status`, `check`, `path`, `get`, `list`,
`version` and `help` never prompt, never take `--yes`, and leave the machine
as they found it. A script, a hook or a job runs them without reading their
help first.

**A mutation with no target does one of two things**, depending on what it
touches.

- A local diff reviewed before it lands (a lockfile, a formatted file, a set
  of links): bare means all. `dev deps update` re-resolves every
  declaration; `dev skills sync` re-materializes every channel. There is no
  `--all` flag; naming targets narrows the verb (`dev deps update cmake`).
- Something irreversible, or state shared with others (an enrollment on
  GitHub, an issue body, a release): bare acts only when exactly one target
  is possible. Otherwise it lists the candidates and asks, or refuses and
  names what to pass. `--yes` skips a confirmation and never picks a target:
  `dev runner unregister --yes` with nothing named is refused.

**A mutation says what it changed.** Its last line names the outcome:
`dev: lockfiles updated — now run dev up to install.`, `pushed <file> to
<issue>`. A stale state found on the way to something else is a message
naming the verb that fixes it — `dependencies.rb changed since the
lockfiles were generated — run dev deps update` — never that verb run on
the user's behalf.

**Help names everything.** `dev help <path>` for a leaf lists each of its
positionals and flags. The one-line description is one sentence with no
synopsis in it; the root listing's second column is that sentence.

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

## Positional arguments

Every builtin declares its positionals, and its usage spells them: the
usage line names each in order — `<name>` for a required one, `[<name>]`
for an optional one, `<name>…` for one that repeats — and an `Arguments:`
block under the description explains each, in the `Flags:` style.

    Usage: dev deps update [<declaration>…]

    Resolve dependency constraints and write lockfiles: every pin moves, or only the named declarations and what they need

    Arguments:
      <declaration>  a dependencies.rb declaration to move to the newest version it admits

A builtin whose grammar is a choice of forms, such as `dev deps path`,
declares a synopsis instead; the usage line prints the synopsis, and the
`Arguments:` block still explains each placeholder it uses.

A builtin's description is one sentence, with no placeholders in it: a
listing's second column is that sentence, and the usage line is where the
grammar lives.

**Project commands have no positional vocabulary.** Their usage line
prints `[args...]`, since the script owns its arguments.

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
| `dev deps update [<declaration>…]` | Resolve `dependencies.rb` and write `deps.lock`: every pin moves to the newest its declaration admits; with names, only those and what they need. |
| `dev deps install [--group <name>] [--except <name>] [--integration <name>] [--pinned-taps]` | Install the lock on this machine. |
| `dev deps check` | Exit non-zero when the manifest, lock, or installed state disagree. |
| `dev deps path ficsit <mod> <platform> \| xcode \| gh <name> \| steam <name> \| egs <name> \| wwise <name>` | Print a locked artifact's path. |
| `dev build [<build>] [--target <target>] [--platform <platform>] [--config <config>] [--runner <label> \| --container]` | Build one target's install. |
| `dev package [<build>] [--target <target>] [--platform <platform>] [--config <config>] [--no-build] [--runner <label> \| --container] [--fetch]` | Build, then archive and stamp the artifact. `--fetch` brings a remote host's artifact into this machine's store. |
| `dev deploy <channel> [<build>] [--release <version>] [--config <config>] [--allow-stale] [--force] [--dry-run] [--runner <label>]` | Ship artifacts to a channel. |
| `dev deploy --release <version> [--dry-run]` | Ship a release to every channel. |
| `dev deploy status [--release <version>]` | What each channel carries. |
| `dev release [<version>\|major\|minor\|patch] [--yes]` | Tag, push, package and attach archives to a GitHub release. |
| `dev cd <query>` | Jump to a checkout by fuzzy name. |
| `dev clone <repo> [--path]` | Clone into the canonical path and land there. |
| `dev config list\|get <key>\|set <key> <value>` | Settings. |
| `dev cred get <namespace> <key>` | Resolve a credential and print it. |
| `dev engine up\|down [--force]\|status` | The per-user container engine. |
| `dev container up\|down\|reset\|status` | This checkout's images and containers. |
| `dev runner register\|status\|unregister [<scope>\|<dir>] [--yes]` | Self-hosted runner enrollment. |
| `dev plan new <title>\|link <n> [<file>] \| <file>\|pull <n>\|push [<plan>]\|status\|init` | Plans as GitHub issues. |
| `dev learnings sync\|status\|invariants\|init` | Org learnings read path. |
| `dev skills status [--json]\|sync` | Agent skill links. |
| `dev cache gc [--keep <n>] [--tool-caches]` | Reclaim caches. |
| `dev version` | Print the version. |
| `dev help [<command>…]` | Usage for any node. |

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
