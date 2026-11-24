# dev.yml reference

`dev.yml` sits at the git root and declares the project's name, its
commands, and — for projects that ship something — its build targets,
deploy channels and release contents.

```yaml
name: myproject

engine:                 # optional: minimum container engine size
  cpus: 8
  memory_gib: 24

commands:
  up:
    desc: Setup dev environment
    run: ./bin/setup.rb
    environment: host
  build:
    desc: Build the project
    run: ./bin/build.sh
    environment: myproject-linux
  test:
    desc: Run tests
    run: ./bin/test.sh
  console:
    desc: Start Ruby console
    run: ./bin/console
    repl: true
  db:
    desc: Database chores
    commands:
      reset:
        desc: Reset the dev database
        run: ./bin/db_reset.sh
```

Every key table below carries the key's type, whether it is required, its
default when omitted, and what it conflicts with or requires. A one-of
value is spelled `a | b`; a nested map has its own section and table.

## Top-level keys

| key | type | required | default | meaning |
|---|---|---|---|---|
| `name` | string | yes | — | Display name, and the key dev stores the project's artifacts under. |
| `engine` | map, see [engine](#engine) | no | none | The smallest container engine this project's builds were tuned for. dev sizes the engine up to it and refuses to run a containerized command on a smaller one. See [Containers](containers.md#engine-resources). |
| `commands` | map of name → [command](#commands) | no | none | The project's commands. |
| `targets` | map of name → [target](#targets) | no | none | What the project builds. Declaring any makes `dev build` and `dev package` exist. |
| `runner_roles` | map of name → role | no | none | Roles `dev runner register --role <name>` enrolls for this repo: `<name>: { labels: [...] }`, plus `group:` and `workflows:` (this repo's, pinned at `v<major>` of `VERSION`) for an org role and `job_identity: <user>` for jobs that run as another user. See [Runners](runners.md#roles). |

### engine

| key | type | required | default | meaning |
|---|---|---|---|---|
| `cpus` | integer | no | none | CPUs the engine needs. |
| `memory_gib` | integer | no | none | Memory the engine needs, in GiB. |
| `disk_gib` | integer | no | none | Disk the engine needs, in GiB. |

## Commands

A command spec has `run`, `commands`, or both.

| key | type | required | default | conflicts / requires | meaning |
|---|---|---|---|---|---|
| `desc` | string | no | `(no description)` | — | One line, shown in listings. |
| `run` | string (shell command) | one of `run`, `commands` | — | — | Run from the repo root. Extra arguments to `dev <cmd>` are appended verbatim, flags included. |
| `commands` | map of name → command, any depth | one of `run`, `commands` | — | no child named `help`; refused with `repl` | Nested specs. With `run` beside it, bare `dev <cmd>` runs `run` and a first argument that is not a child's name is forwarded to it. Without `run`, bare `dev <cmd>` prints usage. |
| `repl` | boolean | no | `false` | refused with `commands` | `true` for consoles and other interactive sessions: the command is exec'd directly, with no `✓ Done` footer. |
| `environment` | image name \| `host` | no | the project's default | — | Where the command runs: an `image` name from `dependencies.rb`, or `host`. See [Where commands run](#where-commands-run). |
| `hidden` | boolean | no | `false` | — | `true` keeps the command callable but out of listings. For plumbing other commands call. |

### Where commands run

A project whose lock pins an `image` block runs commands in a container of
that image unless told otherwise. `environment:` names the image, or `host`
for this machine via `shadowenv exec` (provisioning, deploying, the editor).

When `environment:` is omitted: the project's one image if the lock pins
exactly one; the host if it pins none; refused, with both names listed, if
it pins several. `host` is a reserved name; an image cannot be called that.

Every `environment:` is checked against the lock when `dev.yml` loads, so a
typo fails at `dev help`, not on first run. `dev help` shows each command's
resolved environment as a trailing column — `host`, `myproject-linux`, or
`myproject-linux (container)` when running from here crosses into one.

A host that was itself provisioned from the image runs its commands
natively; see [the host rule](containers.md#the-host-rule).

### Commands on a builtin's name

A project spec on a builtin's name merges with it. `run:` runs after the
builtin's body (the usual case is `up:`). Subcommands merge child by child:
new children are added, same-named children replace the builtin's. `up:`
with only `commands:` keeps bare `dev up` as the builtin and adds the
children.

## Targets

A **target** is one thing the project builds: a client, a dedicated server,
a library, a gem. Each target varies over two optional axes, `platforms`
and `configs`, and dev derives one **build** per combination.

```yaml
targets:
  cellbound-3d-editor:
    desc: Editor (dev test, the fast loop)
    platforms: [linux64, macos]
    environment: { linux64: cellbound-3d-linux, macos: host }
    builder: ./bin/build-editor
    packager: none
  cellbound-3d:
    desc: Client
    platforms: [win64, linux64]
    configs: [dev, release]
    environment: cellbound-3d-linux
    builder: ./bin/build
  snappy-steam:
    desc: Client mod against the Steam game
    platforms: [win64]
    builder: ./bin/build.sh
    packager: as-is
  ue-toolchain:
    desc: The engine toolchain tarball
    builder: ./publisher/build.sh
    packager: { archive: { split: 2GiB } }
  combatmode:
    desc: The addon, zipped by its own script
    builder: ./bin/layout
    packager: ./bin/zip-addon
  rspock:
    desc: The gem
```

A target has two **ports**, a builder and a packager, each declared
under one key named for the port. The value says how the port is
filled: a string is a **script** (a shell command run from the repo
root), a built-in's name or a map of one built-in's name to its options
is that **built-in**.

| key | type | required | default | conflicts / requires | meaning |
|---|---|---|---|---|---|
| `desc` | string | no | `(no description)` | — | One line. |
| `platforms` | list of `win64` \| `linux64` \| `macos` | no | none: builds carry no platform segment | no id twice | The platforms the target builds for. First is the default. |
| `configs` | list of `debug` \| `dev` \| `release` | no | none: builds carry no config segment | no id twice | The configs the target builds in. First is the default. |
| `environment` | image name \| `host` \| map of platform → the same | no | the project's default, as for a command | the map form requires `platforms` and names exactly them | Where the builds run: one value for every build, or one per platform (`{ linux64: img, macos: host }`). |
| `builder` | string \| map | no | the checkout's tracked files (`git ls-files`; nothing ignored or untracked ships) | refused beside `build` | How the **install** — the runnable, staged output — is made. A string is a script writing it into `$DEV_INSTALL`. A map names a built-in builder; dev has none yet, so a map is refused. |
| `packager` | string \| `archive` \| `as-is` \| `none` \| map | no | `archive` | refused beside `package` | How the install becomes the **archive**. A built-in by name, or `{ <name>: { options } }` for one with options; any other string is a script writing the archive at `$DEV_ARTIFACT` plus the extension it chooses. See [Packagers](#packagers). |
| `build` | as `builder` | no | — | refused beside `builder` | Deprecated spelling of `builder`, read as it for one release; loading notes the key to rename. |
| `package` | as `packager` | no | — | refused beside `packager` | Deprecated spelling of `packager`, read as it for one release; loading notes the key to rename. |

### Build names

Builds are named `<target>[-<platform>][-<config>]`, with a segment present
exactly when the target declares that axis: `cellbound-3d-win64-release`,
`cellbound-3d-editor-macos`, `rspock`. A partially qualified name is a
pattern: an omitted segment means the axis's default when running a verb,
or "any" where a set is accepted.

Validation: a target name is lower-case alphanumeric segments joined by
single dashes and may not end in a platform or config id. With targets
declared, `commands: build:` and `commands: package:` are refused at load
(the verbs are derived), and no command may be named like a build. A
`targets:` block this dev cannot read is refused by the verbs it implies,
not at load: see [dev.yml is read by older
devs](#devyml-is-read-by-older-devs).

### Capability

An image declares what it can build with `target_platforms` in its `image`
block (see [Dependencies](dependencies.md#image)). Each platform build is
checked at load against the environment it is placed on: an image that
does not list the platform is refused with the fix named. An image that
declares no `target_platforms` can build nothing with a platform.

`host` builds the platform this machine is. That check happens when a verb
asks for the build, because the same `dev.yml` loads on every machine.

### Packagers

| `packager` | result |
|---|---|
| `archive` (default) | `<build>.zip` of the install's contents, symlinks kept; or, with options, a `.tar.zst`, split or whole, over a selection of the install. See [archive](#archive). |
| `as-is` | The install already is the archive (Alpakit's zip, `gem build`'s `.gem`): its one file is adopted as `<build>.<ext>`. |
| `none` | Built, never shipped. Invisible to `package`, `release` and `deploy`. |
| any other string | A script, run from the repo root, that writes the archive at `$DEV_ARTIFACT` plus the extension it chooses. |

For a packager script with a twist on the default, the hidden `dev pack
DIR [--out STEM] [--format zip|tar] [--split SIZE]` archives any directory
and prints the files it wrote.

### archive

`packager: archive` takes no options; `packager: { archive: { … } }`
takes these:

| key | type | required | default | meaning |
|---|---|---|---|---|
| `format` | `zip` \| `tar` | no | `zip` | `tar` writes `<build>.tar.zst`; needs `zstd` on PATH |
| `split` | size (`2GiB`) | no | none | `tar` only; cuts into `.00`, `.01`, … under the size plus a `<build>.MANIFEST` of SHA-256s; refused with `zip` |
| `vendor` | boolean | no | `false` | a frozen `bundle install` into the stage's `vendor/bundle` before archiving; requires `dependencies.rb` and `deps.lock` in the stage |
| `files` | list of gitignore-syntax patterns | no | the whole stage | applied in order, `!` negating; a bare directory means its contents; paths unchanged; an empty selection is refused with the patterns named |

`split:` alone selects the tar format: `{ archive: { split: 2GiB } }` is
`{ archive: { format: tar, split: 2GiB } }`.

`vendor: true` runs the `bundle install` under the project's Ruby, so the
asset ships the tool's gems and the install writes wrappers only (see [A
tool's closure](dependencies.md#a-tools-closure-at-install-or-at-release)).

`files:` archives only the install's files the list selects, at their
install paths — nothing is rerooted: `{ archive: { files: [/bin, /lib,
/VERSION, "!lib/scratch"] } }`. Patterns are in gitignore syntax and
follow three rules: they apply **in order**, the last matching pattern
deciding; a leading `!` **negates**; a **directory means its contents**
(`/bin` is every file under `bin/`). As in gitignore, a pattern with no
slash matches at any depth (`lib` also takes `test/lib`); a leading or
inner slash anchors it at the install root. A list with no positive
pattern starts from everything (an exclude-only list, like a
`.npmignore`). With `vendor: true` the list also sees `vendor/bundle`, so
list `vendor` to ship it.

A target whose shippable tree is a selection of the checkout needs no
`builder:`: the checkout's tracked files are the install, and `files:`
says which ship. dev's own `dev.yml` is the example — `dev-core` lists
`/bin`, `/lib`, `/share`, `/VERSION`, `/LICENSE`, `/README.md`; the `dev`
deployment lists `/deploy/d3mlabs/config.yml`, `/deploy/d3mlabs/Brewfile`,
`/LICENSE`, `/README.md`, and its formula installs them by those paths.

### The build script's environment

`builder:` and `packager:` scripts read their parameters from the
environment, never from flags:

| Variable | Set when |
|---|---|
| `DEV_TARGET` | always |
| `DEV_PLATFORM`, `DEV_CONFIG` | the target declares that axis |
| `DEV_INSTALL` | always; the install directory, emptied and recreated before a `builder:` script runs — a previous build's files are never there to clear |
| `DEV_ARTIFACT` | `packager:` scripts only; the archive path **without** its extension |

Map dev's ids to the toolchain's switches in the script (`dev → Development`,
`win64 → Win64`), and fail loudly on a name it does not handle
(`*) exit 2`). An axis the target does not declare is unset, so `set -u`
catches a `case` over it.

## Deploy channels

A **channel** is a destination artifacts ship to. Channels are children of
`commands: deploy:`; each becomes `dev deploy <channel>` with its own help
and completion. `deploy` itself has no `run:` and must have children.

```yaml
commands:
  deploy:
    commands:
      staging:
        desc: rsync to the gamebox
        targets: [cellbound-3d-server]
        run: ./bin/stage
        environment: host
      steam:
        desc: Steam depots
        targets: [cellbound-3d-steamworks-win64-release, cellbound-3d-server-linux64-release]
        steam:
          app: 480
          depots:
            cellbound-3d-steamworks-win64: 481
            cellbound-3d-server-linux64: 482
      ficsit:
        targets: [snappy-steam]
```

| key | type | required | default | conflicts / requires | meaning |
|---|---|---|---|---|---|
| `desc` | string | no | `(no description)` | — | One line. |
| `targets` | list of builds or patterns | yes | — | — | The **accept set**: the builds the channel ships. Bare `dev deploy <channel>` ships one artifact per accepted target and platform; a `BUILD` argument narrows it; a build outside the set needs `--force`. |
| `run` | string (shell command) | no | the lock's publisher of the channel's name | refused beside `<channel>:`; required when the lock contributes no publisher of that name | The channel's protocol as a script, run once per archive from the repo root. |
| `environment` | image name \| `host` | no | the project's default, as for a command | requires `run` | Where `run:` executes. |
| `<channel>:` | map (the publisher's options) | no | none | refused beside `run` | The lock publisher's options, under the channel's own name (`steam:` on the `steam` channel). What each publisher reads: [the channel contract](lifecycle.md#the-channel-contract). |

A channel cannot be named `help`, `status` or `releases`, and cannot have
`commands:`.

### Channels from the lock

Integrations with a publisher contribute a channel of their own name:
`steam` for a project pinning a Steam app, `egs` for one pinning Epic's
BuildPatchTool, `rubygems` for one declaring gems, `ghcr` for one pinning
an image, `ficsit` for an SML mod, `brew` for one pinning a formula from a
tap. A declared channel of
the same name **with** `run:` replaces the publisher; one **without**
`run:` configures it (`targets:` and options); a contributed channel the
project does not declare appears as is, accepting every packageable build.
A declared channel with neither `run:` nor a matching publisher is refused
at load.

One publisher is reached by the declaration itself, with no pin: `gh`
ships to the project's own GitHub releases, moving the series tag
`v<major>` and the latest designation ([gh](lifecycle.md#gh)). Declaring
a `gh` channel without `run:` is what contributes it; a project that
declares none has no `deploy gh`.

### The channel script's environment

| Variable | Meaning |
|---|---|
| `DEV_TARGET`, `DEV_PLATFORM`, `DEV_CONFIG` | the artifact's build, as for a `builder:` script |
| `DEV_ARTIFACT` | the archive **file** (with extension) |
| `DEV_CHANNEL` | the channel's name |
| `DEV_TRACK` | `testing` (from the store) or `live` (from a release) |
| `DEV_SCRATCH` | the channel's scratch directory, kept between deploys |
| `DEV_BUILD`, `DEV_BUILD_ID`, `DEV_ARCHIVE_SHA256`, `DEV_SHA` | from the artifact's manifest; `DEV_SHA` is `unknown` outside git |
| `DEV_DIRTY`, `DEV_PACKAGED_AT` | store artifacts only |
| `DEV_RELEASE_VERSION` | release archives only |

The archive is read-only to the script; unpack or stage into `DEV_SCRATCH`.
A nonzero exit ends the deploy at that archive; earlier ones shipped.
Credentials come from `dev cred` or the script's own environment, never
from `dev.yml`.

## Release

`commands: release:` says what a release contains. Declaring it makes `dev
release <version>` exist.

```yaml
commands:
  release:
    desc: Cut a release
    targets: [cellbound-3d-release, cellbound-3d-server-linux64-release]
```

| key | type | required | default | conflicts / requires | meaning |
|---|---|---|---|---|---|
| `desc` | string | no | `(no description)` | — | One line. |
| `targets` | list of builds with the config named | no | every build of every packageable target, allowed when each such target has at most one config | no `packager: none` target | What the release contains: `cellbound-3d-release` means both platforms at release config; `cellbound-3d-win64` spans two configs and is refused with the fully qualified names to pick. |
| `run`, `commands` | — | — | — | refused | A release declaration is not a command. |

What the verbs then do — `build`, `package`, `deploy`, `release`, where
each runs and what it leaves behind — is in [Lifecycle](lifecycle.md).

## dev.yml is read by older devs

Projects pin no dev version ([Configuration](configuration.md#dev-is-live-infrastructure)),
so a `dev.yml` is read by every dev a machine still runs: one written for
the latest release lands on a host whose dev has not upgraded yet, and
dev's own checkout is read by the installed dev before the checkout's code
runs ([CLI](cli.md#inside-devs-own-checkout-dev-is-the-checkout)). `dev up`
is the command that upgrades dev and installs the lock, so a `dev.yml` an
older dev cannot fully read must still `dev up`.

The half of `dev.yml` that grows a grammar is `targets:`, with the
channels and release contents derived from it. A `targets:` block this
dev cannot read — a key it does not know, a packager option it predates —
does not fail the load. The verbs the block implies exist and refuse:
`build` and `package` always, `deploy` and `release` when `commands:`
declares them, each with the key named and the two fixes (upgrade dev, or
fix the declaration). `dev help` lists them as refused; every other
command runs. The rules that need only the block's presence hold as
before: `deploy` and `release` leave the command tree, `commands: build:`
is refused at load. `dev runner register` for a role anchored to the
project's channels refuses too, since the channels derive from what could
not be read.

Everything outside `targets:` — `name`, `engine`, `commands`,
`runner_roles` — is read at load as before; a key an older dev does not
know on a command is ignored, as it always was, and a retired key is
refused with its replacement.
