# Dependencies

`dependencies.rb` declares what a project needs; `deps.lock` pins every
declaration to an exact version; `dev up` installs what the lock names.

## The contract

`dev up` and `dev deps install` read the lock and never resolve: they
install what it names, or refuse. `dev deps update` is the one verb that
writes the lock; bare, it moves every pin to the newest version its
declaration admits, and `dev deps update <name>` moves one declaration
while every other pin stays. `dev deps check` reports the state of the
three (manifest, lock, installed) and changes nothing. Whatever is stale
is a message naming the verb that fixes it, never an action taken on the
reader's behalf.

## The cycle

1. Declare in `dependencies.rb`.
2. `dev deps update` resolves the declarations and writes `deps.lock`.
   Commit both.
3. `dev up` installs the lock on this machine and activates it for the
   project's commands.

After editing `dependencies.rb`, run `dev deps update` before `dev up`;
every command warns (errors in CI) while the manifest and lock disagree.

## Three levels of adoption

Take whichever you need:

1. **Commands only** — a `dev.yml`, no `dependencies.rb`. dev runs your
   scripts and touches nothing else.
2. **A pinned interpreter** — `dependencies.rb` with only `ruby "4.0.6"`.
   dev installs that Ruby and every command runs under it. Your Gemfile
   stays yours.
3. **Managed dependencies** — gems, formulae, engine archives and so on in
   `dependencies.rb`. dev generates the `Gemfile` from `gem` declarations
   and installs everything from the lock.

## Declaring

```ruby
require "dev/deps"

Dev::Deps.define do
  ruby "4.0.6"                 # the project Ruby
  python "3.12"                # optional: a Python and a project .venv
  gem "cli-ui"                 # default bundler group
  tap "d3mlabs/d3mlabs"        # a brew tap formulae below may come from

  image "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3" do
    platform "linux/amd64"
    apt "winbind", "dos2unix"
    target_platforms :win64, :linux64
  end

  group :build do
    brew "cmake"
    brew "llvm", "~22"
    env :ci do
      brew "ruby"
    end
  end

  group :app do
    cmake "boost", url: "https://example.com/boost-1.90.0.tar.gz", tag: "boost-1.90.0"
    cmake "cereal", github: "USCiLab/cereal", tag: "v1.3.2"
  end

  group :test do
    cmake "googletest", github: "google", tag: "v1.17.0", targets: ["gtest", "gmock"]
    luarocks "luaunit", ">= 3.5"
  end

  group :anatomy, host: :darwin do
    pip "totalsegmentator", ">= 2.0"
  end
end
```

### Directives

Every directive that declares a package takes an optional requirement as
its second argument, in semver range syntax: `"4.0.1"` is exactly that
version, `"^1.2"` is any 1.x from 1.2.0, `"~18"` is any 18.x, `">=2 <3"`
is a range. Without one the directive asks for any version, and
`dev deps update` locks the highest the channel publishes.

| Range | Means | Reads as |
|---|---|---|
| `1.2.3`, `=1.2.3` | exactly 1.2.3 | — |
| `^1.2.3` | `>=1.2.3 <2.0.0` | compatible: the leftmost non-zero segment holds (`^0.2.3` is `>=0.2.3 <0.3.0`) |
| `^1`, `^1.2` | `>=1.0.0 <2.0.0`, `>=1.2.0 <2.0.0` | the same, over a partial version |
| `~1.2.3` | `>=1.2.3 <1.3.0` | patch range: the last written segment's parent holds |
| `~1`, `~1.2` | `>=1.0.0 <2.0.0`, `>=1.2.0 <1.3.0` | the same, over a partial version |
| `>=1.0.0 <2.0.0` | both | comparators (`= > >= < <=`), whitespace or a comma between |

A version is semver's — `MAJOR[.MINOR[.PATCH]][-prerelease][+build]` —
for `^` and `~`, which bump it; a comparator or an exact takes the
channel's own version shape as written (brew's `3.11.4_1`, pip's
`3.0rc1`). A prerelease (`2.0.0-rc.1`) is a candidate only where a term
names a prerelease of that very release (`>=2.0.0-0`); `^1` never picks
`2.0.0-rc.1`, and a bare directive never picks a prerelease at all.
bundler's `~>` is not a range here: `dev up` refuses it naming the
spelling it maps to (`~> 1` → `^1`, `~> 1.2` → `^1.2`, `~> 1.2.3` →
`~1.2.3`); the Gemfile dev generates is where bundler's grammar is
written. Some directives also take the channel's own
spelling as a keyword (`brew "llvm", version: "18"`, `gh ..., tag: "v1.0"`);
a directive given both refuses.

A channel that cannot pick among versions refuses a range when the lock is
written, naming what it takes: a cask takes no requirement, a Steam app
takes none or an exact `buildid:`, and a formula brew has one version of
takes none or that version.

| Directive | Declares | Installed by |
|---|---|---|
| `ruby "X.Y.Z"` | The project Ruby. `"4.0.6"` exact, `"~4.0"` highest 4.0.x at lock time, `"4.0"` any 4.0.x. | brew, from the d3mlabs tap's `ruby@X.Y.Z` formulae |
| `python "3.12"` | The project Python and a `.venv` built on it. | brew (`python@3.12`), then `venv` |
| `gem "name" [, "req"]` | A gem. The requirement is written into the generated `Gemfile` as the comparators it means (`"^1.17"` → `">= 1.17.0", "< 2.0.0"`); dev generates `Gemfile.lock`. A group becomes a bundler group. Other keywords (`require:`, `git:`) are gem options. | `bundle install` |
| `brew "name" [, "req"] [, version:]` | A formula, chosen among the versions brew publishes for it and its `name@N` siblings. `brew "llvm", "~18"`, `brew "llvm", version: "18"` and `brew "llvm@18"` are the same declaration. `cask: true` declares a cask by its whole name (`brew "temurin@21", cask: true`), which takes no requirement. | `brew install` at the locked version |
| `tap "owner/repo" [, url:]` | A tap formulae may come from. | `brew tap` |
| `gh "name" [, "req"], github: "owner/repo", tag: \| sha:, assets:` or `build:` | A GitHub release by `tag:` (the tag as spelled), by a requirement over the repo's version tags (`"^3.11"`, a leading `v` read past), or a commit by full 40-hex `sha:`. One of the three is required; a gh pin never floats to the latest release. A requirement that names whole series (`"^1"`, `">=1 <2"`, `">=1"`) resolves through the repo's **series head** where it keeps one — the version the series tag `v<major>` points at, what `dev deploy gh` moves and an adopter's `@v1` resolves — and to the greatest satisfying tag where it keeps none; a bound inside a series (`">=1.4"`) is always the greatest satisfying tag ([Series heads](#series-heads)). `assets:` selects prebuilt release assets by glob — a zip or a `.tar.zst` (whole or split), the two forms `dev package` writes; `build:` builds from the source archive. A `sha:` pin has no release, so it takes `build:` only. A tree carrying its own `dependencies.rb` and `deps.lock` is installed self-contained ([below](#self-contained-trees)). | download into the store |
| `cmake "name" [, "req"], github:/url:, tag:/branch:/commit: [, targets:]` | A CMake source dependency, linked at `build/_deps/<name>-src`. `tag:` and `branch:` name a ref; a requirement ranges over the repo's version tags; `commit:` is a full 40-hex SHA. | checkout into the store |
| `luarocks "name" [, "req"]` | A rock. Transitive deps resolved by luarocks at install. | `luarocks install` |
| `pip "name" [, "req"]` | A package in the project venv; `~2.0.3` reads as pip's `~=2.0.3`. Transitive deps resolved by pip at install. Needs `python`. | `pip install` |
| `ficsit "ModRef" [, "req"] [, version:]` | A Satisfactory mod from SMR. `version:` is the same requirement under the keyword SMR writes it as (`version: "^3.12.0"`). | download |
| `steam "name" [, "= buildid"], app: [, branch:, buildid:]` | A Steam app or depot via SteamCMD, following `branch:` (default `public`). `buildid:` asserts the branch is still at that build. | `steamcmd` |
| `egs` | Epic's BuildPatchTool. Pinning it gives the project a `deploy egs` channel. | download |
| `xcode "26.1.1"` | The Xcode toolchain. macOS only. | `xcodes install`; publishes `DEVELOPER_DIR` |
| `wwise "Wwise", sdk:, integration:, ue: [, packages:, deployment_platforms:]` | The Wwise SDK with its Unreal integration. | `wwise-cli` |
| `image "name", from: do … end` | A build environment image. See [image](#image). | docker, see [Containers](containers.md) |
| `register :verb, Klass` | A project-local integration. See [Custom integrations](#custom-integrations). | yours |

`github: "org/repo"` expands to the repo URL. `github: "org"` alone appends
the dependency name as the repo.

Which directive a new dependency should use, and when something is
repackaged into the org tap instead: [deps-channels.md](deps-channels.md).

### Scoping a declaration

Four independent axes:

| Axis | Values | Meaning |
|---|---|---|
| `group` | any symbol (`:app`, `:test`, `:build`, …) | Purpose. Selected at install with `--group` / `--except`. |
| `env` | `:ci`, `:dev` | The execution context. `env :ci do … end` inside a group. Detected from the `CI` variable. |
| `host` | `:darwin`, `:linux` | The OS the dependency installs on. Per group (`group :editor, host: :darwin`) or per declaration (`gh …, host: :linux`). Dependencies for other hosts are still locked. |
| `platform` | integration-specific (`"LinuxServer"`) | The artifact variant, for integrations like ficsit and steam. |

Nothing installs first because of its group's name; install order follows
the lock's dependency graph.

### image

```ruby
image "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3" do
  platform "linux/amd64"                  # optional when the floor publishes one
  apt "winbind", "dos2unix"               # OS packages on top of the floor
  target_platforms :win64, :linux64       # what this environment's toolchain can build
  persist true                            # keep one container per checkout
  volume "~/.dev/engines/ue:/ue"          # extra host:container mounts
  run_env "WWISE_TOKEN" => "wwise/token"  # credentials injected as -e, from dev cred
end
```

`from:` is the base image, resolved to its digest at lock time. `apt` lines
are the only OS packages a project declares. dev generates the Dockerfile
and the image's tag is the Dockerfile's SHA-256, so a changed floor or
package set is a lock diff and a new tag. `target_platforms`, `persist`,
`volume` and `run_env` do not enter the image; they describe what it can
build and how its container starts. How the image is resolved, published
and run: [Containers](containers.md).

### Integration tooling

An integration that needs a tool of its own (`xcode` needs `xcodes`,
`wwise` needs `wwise-cli`) declares it in a manifest of its own. When your
project uses the integration, `dev deps update` locks that tool into your
lock as an ordinary pin marked `needed_by`, and `dev deps install` installs
it first. Declaring the same tool yourself merges when the versions agree
and errors when they do not.

### Custom integrations

```ruby
require_relative "lib/my_integration"

Dev::Deps.define do
  register :my_type, MyIntegration

  group :app do
    my_type "some_dep", ">= 1.0"
  end
end
```

An integration implements `Dev::Deps::Integration` (`install_all(pins,
root:)`) and `Dev::Deps::Repository` (`find(id)`), and registers a
`Dev::Deps::VersionScheme` saying how its versions order.
A `dependencies.rb` beside the class file declares the integration's own
tooling. Design notes: [deps-architecture.md](deps-architecture.md).

## The lock

`deps.lock` is one YAML file pinning every dependency in every group to an
exact version plus integrity facts, nested by integration. `dev deps
update` writes it; commit it; never edit it by hand.

A lock records what a dependency publishes, not the machine that wrote it.
A pin with one published file carries that file's hash; a pin with several
platform builds carries a `platforms:` block with every published target
(brew bottle tags, ficsit targets). A pin also carries its `source`: the
fully qualified reference its service installs exactly this version from
(a commit, a digest, `tap@commit`, `name==version`), which is what lets
`dev deps update <name>` keep it. The same `dev deps update` on a Mac and
a Linux box writes the same bytes.

An `image` pin carries the floor's tag and digest, the platform, the sorted
`apt` set, `target_platforms` when declared, and the generated Dockerfile's
digest. A dev that computes a different digest for the lock on disk refuses
to run and names `dev deps update`.

Platform words mean different things in different places: a dependency's
`platforms:` block is keyed by the publisher's names (`arm64_tahoe`,
`x86_64_linux`, `LinuxServer`); an image's `platform:` is docker's
(`linux/amd64`); `group host:` is `:darwin` / `:linux`; `target_platforms`
is dev's build set (`win64`, `linux64`, `macos`).

## Commands

### `dev deps update [<declaration>…]`

Resolves `dependencies.rb` and writes `deps.lock`. Bare, it is `bundle
lock --update`: after `brew update`, every pin moves to the newest version
its declaration admits, so the lock is today's for every channel at once.
Naming declarations is `bundle update <gem>`: the named declarations and
what they pull in re-resolve, and every other pin is copied from the lock —
provided its declaration still asks the same thing (group, scope, tap or
floor, constraint) and the lock records a `source` for it.

A pin's `source` is the fully qualified reference its service gave it: a
git or gh commit, an image digest, `name==version` for pip, `tap@commit`
for brew. A pin without one cannot be kept — nothing could install exactly
it again — so `update <name>` re-resolves it and says so once; from then on
the lock has its source. A steam pin never has one (SteamCMD installs a
branch tip and publishes no way to install a past build), so the lock's
header names it as re-resolved on every update, as does `dev deps check`.

The output names every pin that moved; under `update <name>` each move
beyond the names given carries its cause (`declaration changed`, or that
the lock records no source for the old pin). A move on a channel that
keeps series heads says which rule chose the version — `series head v1 →
1.3.0` (the version as the repo's tags spell it), or `greatest
satisfying` where the ask passed the heads over ([Series
heads](#series-heads)); on a channel with no heads there is one rule and
nothing to say. It
also warns per brew formula the image build would compile from source
because its tap ships no `x86_64_linux` bottle. When `brew update` fails
(offline, a prefix this user cannot write) the update warns and resolves
against the index brew has.

### Series heads

A channel whose store keeps a movable pointer per series — a gh repo's
`v1`, `v2` tags, moved by `dev deploy gh` ([lifecycle.md](lifecycle.md#gh))
— has a **head** per series: the release the pointer names. A
requirement that covers whole series and nothing finer is
**series-shaped**: `^1` and `>=1 <2` name series 1; `>=1` names
every series from 1 on. On such a channel a series-shaped requirement
resolves to the head of the newest series it covers that has one — the
version *and* the commit `v<major>` points at — so the lock reads the
same pointer an adopter's `uses: …@v1` resolves through. Rolling a deploy back
(`dev deploy gh --release 1.3.0` while 1.4.0 is cut) moves `v1`, and the
next `dev deps update` locks 1.3.0 again; nothing re-locks the version
the operator just rolled away from.

Where the covered series have no pointer — a repo with no series tags,
a series released but never deployed — the requirement resolves as every
requirement does on a derived channel: the greatest satisfying version.
A requirement with a bound inside a series (`>=1.4`, `^1.2`) names
versions, not series, and is the greatest satisfying version on every
channel; `tag:` and `sha:` are exact. `dev deps update` says which rule
chose each moved pin:

```
dev: moved ai-flow 1.4.0 → 1.3.0 (series head v1 → 1.3.0)
dev: added ai-flow-newest 1.4.0 (greatest satisfying)
```

A series tag stays a version of the universe too — `tag: "v1"` names it
exactly, as it always did. It is read as a pointer only when a release
of its major sits at its commit; a `v<major>` tag at any other commit is
a version like any tag and names no head.

### `dev deps install [--group G]… [--except G]… [--integration I]… [--pinned-taps]`

Installs the lock on this machine, filtered to the detected env and host.
`--group` keeps only the named groups; `--except` drops them and wins;
`--integration` keeps only the named lock keys (`brew`, `gh`, `bundler`,
…). Interpreters are pins like any other, so an image bootstrap's
`--group build --integration brew` never installs the project Ruby.
`--pinned-taps` installs brew formulae from taps checked out at the lock's
commits; image builds use it by default.

Finishes by refreshing agent skill links ([Agents](agents.md)).

### `dev up`

Converges the host layer ([Configuration](configuration.md#host-tooling)),
installs the lock, brings the build container up if the lock pins an image
([Containers](containers.md)), then runs the project's `up:` command.
Outside a project it converges the host layer only. `--no-cache` runs the
project half from an empty data root ([Containers](containers.md#the-cold-run)).

### `dev deps check`

Exits non-zero when `dependencies.rb` and `deps.lock` disagree, or when
`deps.lock` differs from what this machine last installed. The same checks
run at every command start. It also names each pin the lock cannot keep
across updates (a steam branch tip), so a lock that moves on every
`dev deps update` is no surprise.

### `dev deps path <integration> <name> [<platform>]`

Prints a locked artifact's absolute path: `dev deps path gh
UnrealEngineMac`, `dev deps path xcode`, `dev deps path ficsit SML
LinuxServer`, `dev deps path wwise Wwise`. Scripts use this instead of
reconstructing the store layout.

## What `dev up` does per directive

### ruby

Installs the locked Ruby as a brew bottle, creates the project's gem home
under the data root, and writes two files at the repo root:

- `.shadowenv.d/510_ruby.lisp` — puts the Ruby on `PATH` and sets
  `GEM_HOME` to the project's gem home,
  `<data root>/gems/<name>/<host|container>/<keg version>`, where `<name>`
  is dev.yml's `name`. `GEM_PATH` is that gem home followed by the keg's
  own gem directory, so the Ruby's default gems stay loadable.
  Machine-specific; gitignored ([the list](gitignore.md)).
- `.ruby-version` — the bare version string, for tools that are not
  shadowenv-aware (RubyMine, Bundler's `ruby file:`, setup-ruby). **Commit
  it.** `dev up` rewrites it from the lock every run, so edit
  `dependencies.rb` to change the Ruby, not this file.

Two projects locking two patches each run their own; the kegs coexist. Two
projects locking one patch share the keg and nothing else: each has its own
gem home, so `bundle install` in one never touches the other and `bundle
clean` reclaims only its own. The gem home is the user's, not the brew
prefix owner's, so a user who does not own the prefix installs gems without
writing the keg. A project that declares no `ruby` runs its commands under
whatever Ruby the shell has.

### python

Installs the locked Python through brew, builds the project venv on that
keg under the data root, and links it as `.venv` at the repo root
(`.venv-container` inside the build container). Both links are gitignored
([the list](gitignore.md)). The venv's `VIRTUAL_ENV` and `bin` enter the
project environment. `pip` declarations install into it.

### gem

Writes `Gemfile` and `Gemfile.lock` from the declarations and runs `bundle
install` — on the host against the host Ruby, and again inside the build
container against the container's.

### brew

Installs each formula at its locked version and verifies a matching keg
exists afterwards; a mismatch fails with `VersionMismatchError`. If the
installed version differs from the lock, dev installs the locked version
from the formula's tap at the commit the lock recorded. Casks are not
verified.

The project runs the locked keg, not whatever brew has linked: `dev up`
writes `.shadowenv.d/515_brew.lisp` putting each locked formula's `bin`
first on `PATH`, so two checkouts can use two versions of one formula. dev
also adds locked formulae to `HOMEBREW_NO_CLEANUP_FORMULAE` so your `brew
cleanup` never removes a keg a lock names.

If the lock is stale — the formula at the locked commit no longer installs
— the error says so; run `dev deps update`. Design notes:
[ADR-0003](DECISIONS.md#adr-0003--a-brew-lock-has-bite-on-both-sides),
[ADR-0005](DECISIONS.md#adr-0005--a-taps-commit-moves-only-when-its-pins-move).

### xcode

Installs `/Applications/Xcode-<version>.app` through `xcodes` and publishes
`DEVELOPER_DIR` into the project environment. Interactive runs pass Apple
ID, 2FA and sudo prompts through to you; headless runs fail with the
remediation. Pre-install once by hand on a CI runner.

### wwise

Downloads the SDK and Unreal integration into `~/.dev/wwise/<sdk>/` with
`wwise-cli`, laid out as its cache so a container can mount it read-only
and run `wwise-cli integrate-ue --offline`. The Audiokinetic login comes
from `dev cred` as `wwise/email` and `wwise/password`
(`WWISE_EMAIL` / `WWISE_PASSWORD` in the environment first), read only when
the locked version is not yet downloaded.

### gh, steam, cmake, ficsit, egs

Downloaded or checked out into version-keyed trees under the data root;
see [Data root](data-root.md). Projects reach them through `dev deps path`
or, for `cmake`, the `build/_deps/<name>-src` link `dev up` maintains. A
`gh` tree that ships a `bin/` is also put on the project `PATH` through
`.shadowenv.d/515_gh.lisp`.

#### Self-contained trees

A target that ships its manifest and lock — `dependencies.rb` and
`deps.lock` in the released tree — is installed **self-contained**: dev
converges the tree's dependencies into the tree and writes one
`bin/<name>` launcher per `exe/<name>`; the tree exports nothing. A
target that ships neither is a plain asset: dev downloads and extracts
it, and a `bin/` it carries goes on the project `PATH` as above.

Self-contained means nothing of the caller's project — no gems, no lisp,
no environment — is needed to run the tree's executables, and nothing of
the tree enters the project's lock, gem home or environment; the
consumer records one pin and gets the tree's `bin/` on `PATH`. A
toolchain keg the tree's lock pins is the one thing shared, and brew owns
it, host-level, as for every project.

The property is of the tree's content, decided per target by what its
`files:` ship, not of the project that releases it. dev's own targets
and the one it is written for:

| target | ships `dependencies.rb` + `deps.lock` | installed as |
|---|---|---|
| ai-flow | yes | self-contained: its pinned Ruby through brew, its gems vendored into the tree, a launcher per `exe/` |
| `dev-core` | no — the manifest and locks stay out by design | a plain tree; the `dev-core` formula owns its runtime, so the tree is framework-dependent |
| `dev` (the d3mlabs deployment) | no — it ships no program, only `config.yml` and the `Brewfile` | a plain asset the `dev` formula installs by name |

Converging the dependencies is each ecosystem's work. For a Ruby tree —
the one ecosystem today — it is the gem integration's steps, in bundler's
words. Before the tree publishes, `dev up` reads the tree's lock, installs
the Ruby it **pins** through brew, runs a frozen `bundle install` so the
gems are **vendored** into the tree's own `vendor/bundle` under that
keg's bundler, and writes a **binstub**-shaped launcher per executable.
The vendored gems live and are collected with the tree; no project gem
home is touched.

The launcher is `bin/dev`'s sh half and nothing more: it unsets the
harness activation (`RUBYOPT`, `RUBYLIB`, `BUNDLE_*`, `BUNDLER_*` — the
same list `bin/dev` unsets) and execs the keg's Ruby on `exe/<name>`. It
exports nothing, and `GEM_HOME`/`GEM_PATH` pass through untouched: they
are the caller's gem environment, and the tool's children (a `dev` it runs
in a checkout, an agent's `bundle exec`) inherit them as they would from
any other process.

Selecting the tree's gems is the executable's job, in-process, the way
`bin/dev` selects dev's own. Bundler lays the vendored gems under
`vendor/bundle/ruby/<ruby_version>` — a gem home — so an `exe/<name>`
finds them by position relative to `__dir__` and puts them in front of
the Ruby's own bundled gems, nothing from the environment:

```ruby
tree = File.expand_path("..", __dir__)
tree_gems = File.join(tree, "vendor/bundle/ruby", RbConfig::CONFIG["ruby_version"])
ruby_own_gems = File.join(RbConfig::CONFIG["rubylibprefix"], "gems", RbConfig::CONFIG["ruby_version"])
Gem.use_paths(tree_gems, [tree_gems, ruby_own_gems])
```

`Gem.use_paths` touches no `ENV`, so the executable's gem selection is
invisible to its children. With the launcher's unset in front of it, the
tool works the same from any project — or from no project — under any
caller's activation.

The release side has the same shape. A target with `packager: { archive:
{ vendor: true } }` vendors the bundle into the stage before archiving
it, so the asset ships the gems; installing such a tree asks brew for the
Ruby and writes the launchers only. Vendoring binds the asset to a
platform when any gem compiles a native extension — pure-Ruby tools ship
one asset for every machine.

A gh tree is keyed by its version alone, so the converged tree is the
first installing machine's: a tree is per data root, and a data root is
per machine or per side of a build container.

Whether a tree is **complete** for that install — the lock beside the
manifest, a Ruby pinned for the executables and gems to run under, an
`exe/` to write launchers for, no `bin/<name>` an `exe/<name>`'s launcher
would overwrite — is checked where the producer can fix it: the `gh`
channel refuses an incomplete tree at `dev package`, before the release
is cut and immutable ([`dev package`](lifecycle.md#dev-package)). The
install's own refusals on the host stay as the last line of defence.

A steam pin is the branch's build id at lock time, with no `source`:
SteamCMD's `app_update` installs the branch tip, and its `download_depot`
writes one depot's files without the app manifest and refuses large
depots, so no past build is installable by reference. `dev deps update`
re-resolves it every time, and the lock's header says so.

## What the checkout carries

Committed: `dependencies.rb`, `deps.lock`, `.ruby-version`, and the
generated `Gemfile` / `Gemfile.lock` when gems are declared. Gitignored:
the activation state `dev up` writes for this machine. The full list, with
the command that writes the ignore lines:
[What dev writes into a checkout](gitignore.md).
