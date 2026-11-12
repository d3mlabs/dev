# dev

[![codecov](https://codecov.io/gh/d3mlabs/dev/branch/main/graph/badge.svg)](https://codecov.io/gh/d3mlabs/dev)

`dev` is a command runner and dependency manager for a project checkout. A
repo declares its commands in `dev.yml` and its dependencies in
`dependencies.rb`; `dev up` provisions the machine from those two files, and
`dev <command>` runs a command with the right toolchain active.

It solves the "works on my machine" problem across macOS, Linux and WSL2:
one lockfile pins every dependency — interpreters, brew formulae, gems,
engine archives, build images — and every host installs exactly what the
lock names.

## Install

```bash
brew install d3mlabs/d3mlabs/dev   # tool + d3mlabs org config
gh auth login                      # dev downloads private assets through gh
dev up                             # installs shell hooks; open a new shell after
```

Individuals outside an org install `d3mlabs/d3mlabs/dev-core` instead and
set their own config; see [Configuration](docs/configuration.md).

**Windows** runs dev inside WSL2. Once, from an elevated PowerShell:
`wsl --install -d Ubuntu`, then in Ubuntu
[install Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux) and run
the three lines above.

## Quick start

Clone a project that already uses dev and provision it:

```bash
dev clone d3mlabs/myproject   # clones under ~/src/github.com/<org>/<repo> and cd's there
dev up                        # installs the lock, brings the build container up if any
dev                           # lists the project's commands
dev test                      # runs one
```

To add dev to a project, create two files at the repo root.

`dev.yml` declares the commands:

```yaml
name: myproject
commands:
  up:
    desc: Install the app's own dependencies
    run: ./bin/setup
  test:
    desc: Run the tests
    run: ./bin/test
  console:
    desc: Start a console
    run: ./bin/console
    repl: true
```

`dependencies.rb` declares what the commands need:

```ruby
require "dev/deps"

Dev::Deps.define do
  ruby "4.0.6"
  brew "cmake"

  group :test do
    gem "rspock"
  end
end
```

Then lock and install:

```bash
dev deps update   # resolves dependencies.rb into deps.lock; commit the lock
dev up            # installs what the lock names, then runs the project's `up`
dev test          # runs under the locked Ruby, with locked formulae on PATH
```

Each file is optional. A `dev.yml` alone gives you the command runner; a
`dependencies.rb` with only `ruby` gives you a pinned interpreter; a full
`dependencies.rb` gives you locked dependencies and generated `Gemfile`.

## Usage

```bash
dev                       # list the commands available here
dev <command> [args...]   # run one; extra args go to the command verbatim
dev help <command>        # usage for any command or group
```

dev reads the `dev.yml` at the root of the enclosing git repo. Commands come
in two kinds: project commands declared in `dev.yml`, and builtins that ship
with dev. Commands nest (`dev deps update`, `dev runner status`), and Tab
completion follows the tree once the shell hook is installed.

The builtins:

| Command | What it does | Docs |
|---|---|---|
| `dev up` | Install the lock, bring services up, run the project's `up` | [Dependencies](docs/dependencies.md) |
| `dev down` | Stop this checkout's containers | [Containers](docs/containers.md) |
| `dev deps update\|install\|check\|path` | Lock, install, verify, locate dependencies | [Dependencies](docs/dependencies.md) |
| `dev build\|package\|deploy\|release` | Build, archive, ship and release the project's targets | [Lifecycle](docs/lifecycle.md) |
| `dev cd <repo>` / `dev clone <repo>` | Jump to or clone a checkout by name | [Shell](docs/shell.md) |
| `dev config list\|get\|set` | Read and write dev's settings | [Configuration](docs/configuration.md) |
| `dev cred get <ns> <key>` | Resolve a stored credential | [Shell](docs/shell.md#dev-cred) |
| `dev engine up\|down\|status` | The per-user container engine | [Containers](docs/containers.md) |
| `dev container up\|down\|reset\|status` | This checkout's build containers | [Containers](docs/containers.md) |
| `dev runner register\|status\|unregister` | Enroll this machine as a self-hosted runner | [Runners](docs/runners.md) |
| `dev plan new\|link\|pull\|push\|status\|init` | Sync Cursor plans with GitHub issues | [Agents](docs/agents.md) |
| `dev learnings sync\|status\|invariants\|init` | Sync org learnings into the machine | [Agents](docs/agents.md) |
| `dev skills status\|sync` | Inspect agent skill links | [Agents](docs/agents.md) |
| `dev cache gc` | Reclaim caches and old artifacts | [Data root](docs/data-root.md) |
| `dev version`, `dev help` | | |

`-h`/`--help` on any builtin prints its usage; unknown flags are refused
with exit 2. Project commands receive their arguments untouched. Details and
error messages: [CLI conventions](docs/cli.md).

## Documentation

In the order a new user needs them:

1. [CLI conventions](docs/cli.md) — command resolution, flags, errors.
2. [dev.yml reference](docs/dev-yml.md) — commands, targets, deploy
   channels, releases.
3. [Dependencies](docs/dependencies.md) — `dependencies.rb`, the lock,
   integrations, `dev deps`.
4. [Configuration](docs/configuration.md) — settings, org deployment
   formulas, host tooling.
5. [Shell integration](docs/shell.md) — `dev cd`, `dev clone`, completion,
   `dev cred`.
6. [Containers](docs/containers.md) — the engine, the `image` block, where
   commands run.
7. [Data root](docs/data-root.md) — where dev stores things, `dev cache gc`.
8. [Lifecycle](docs/lifecycle.md) — `build`, `package`, `deploy`,
   `release` in full.
9. [Runners](docs/runners.md) — self-hosted and hosted runners, agent hosts.
10. [Agents](docs/agents.md) — plans, skills, learnings.
11. [Writing scripts for dev](docs/scripts.md) — terminal, spinners,
    environment.

For maintainers: [Releasing dev](docs/releasing.md),
[Sorbet](docs/sorbet.md), the design records in
[DECISIONS.md](docs/DECISIONS.md), and the architecture notes
[deps-architecture.md](docs/deps-architecture.md),
[deps-channels.md](docs/deps-channels.md) and
[lifecycle-architecture.md](docs/lifecycle-architecture.md).
