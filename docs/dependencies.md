# Dependencies

`dependencies.rb` declares what a project needs; `deps.lock` pins every
declaration to an exact version; `dev up` installs what the lock names.

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
    brew "llvm", version: "22"
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
    luarocks "luaunit", ">=3.5"
  end

  group :anatomy, host: :darwin do
    pip "totalsegmentator", ">=2.0"
  end
end
```

### Directives

| Directive | Declares | Installed by |
|---|---|---|
| `ruby "X.Y.Z"` | The project Ruby. A rubygems requirement: `"4.0.6"` exact, `"~> 4.0"` highest 4.0.x at lock time. | brew, from the d3mlabs tap's `ruby@X.Y.Z` formulae |
| `python "3.12"` | The project Python and a `.venv` built on it. | brew (`python@3.12`), then `venv` |
| `gem "name" [, "req"]` | A gem. dev generates `Gemfile` and `Gemfile.lock`. A group becomes a bundler group. | `bundle install` |
| `brew "name" [, version:]` | A formula. | `brew install` at the locked version |
| `tap "owner/repo" [, url:]` | A tap formulae may come from. | `brew tap` |
| `gh "name", github: "owner/repo", tag: \| sha:, assets:` or `build:` | A GitHub release by `tag:`, or a commit by full 40-hex `sha:`. `assets:` selects prebuilt release assets by glob; `build:` builds from the source archive. A `sha:` pin has no release, so it takes `build:` only. | download into the store |
| `cmake "name", github:/url:, tag:/branch:/commit: [, targets:]` | A CMake source dependency, linked at `build/_deps/<name>-src`. | checkout into the store |
| `luarocks "name" [, "req"]` | A rock. Transitive deps resolved by luarocks at install. | `luarocks install` |
| `pip "name" [, "req"]` | A package in the project venv. Transitive deps resolved by pip at install. Needs `python`. | `pip install` |
| `ficsit "ModRef" [, version:]` | A Satisfactory mod from SMR. | download |
| `steam "name", app: [, branch:, buildid:]` | A Steam app or depot via SteamCMD. | `steamcmd` |
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
    my_type "some_dep", version: ">=1.0"
  end
end
```

An integration implements `Dev::Deps::Integration` (`install_all(pins,
root:)`) and `Dev::Deps::Repository` (`resolve(name, constraint, cache:)`).
A `dependencies.rb` beside the class file declares the integration's own
tooling. Design notes: [deps-architecture.md](deps-architecture.md).

## The lock

`deps.lock` is one YAML file pinning every dependency in every group to an
exact version plus integrity facts, nested by integration. `dev deps
update` writes it; commit it; never edit it by hand.

A lock records what a dependency publishes, not the machine that wrote it.
A pin with one published file carries that file's hash; a pin with several
platform builds carries a `platforms:` block with every published target
(brew bottle tags, ficsit targets). The same `dev deps update` on a Mac and
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

### `dev deps update [<name>…] [--all]`

Resolves `dependencies.rb` and writes `deps.lock`. The re-lock is
conservative, like `bundle install` against an existing `Gemfile.lock`: a
pin whose declaration did not change keeps its locked version. Naming
declarations re-resolves only those and what they pull in (`bundle update
<gem>`); `--all` takes the registries' current version for every pin.

The output names every pin that moved and why (`named`, `--all`,
`declaration changed`), and warns per brew formula the image build would
compile from source because its tap ships no `x86_64_linux` bottle.

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
run at every command start.

### `dev deps path <integration> <name> [<platform>]`

Prints a locked artifact's absolute path: `dev deps path gh
UnrealEngineMac`, `dev deps path xcode`, `dev deps path ficsit SML
LinuxServer`, `dev deps path wwise Wwise`. Scripts use this instead of
reconstructing the store layout.

## What `dev up` does per directive

### ruby

Installs the locked Ruby as a brew bottle and writes two files at the repo
root:

- `.shadowenv.d/510_ruby.lisp` — puts the Ruby on `PATH` and sets
  `GEM_HOME` to the keg's own gem directory. Machine-specific; gitignore it.
- `.ruby-version` — the bare version string, for tools that are not
  shadowenv-aware (RubyMine, Bundler's `ruby file:`, setup-ruby). **Commit
  it.** `dev up` rewrites it from the lock every run, so edit
  `dependencies.rb` to change the Ruby, not this file.

Two projects locking two patches each run their own; the kegs coexist. A
project that declares no `ruby` runs its commands under whatever Ruby the
shell has.

### python

Installs the locked Python through brew, builds the project venv on that
keg under the data root, and links it as `.venv` at the repo root
(`.venv-container` inside the build container). Gitignore both links. The
venv's `VIRTUAL_ENV` and `bin` enter the project environment. `pip`
declarations install into it.

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

## What the checkout carries

Committed: `dependencies.rb`, `deps.lock`, `.ruby-version`, and the
generated `Gemfile` / `Gemfile.lock` when gems are declared.

Gitignored: `.shadowenv.d/`, `.venv`, `.venv-container`, `build/_deps/`.
Full list: [deps-channels.md](deps-channels.md#what-the-checkout-carries-and-gitignores).
