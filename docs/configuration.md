# Configuration

dev ships org-blank. Everything org-specific — which plans repo, which
knowledge repo, which formula to self-update — is a setting, and an org
delivers its settings through a deployment formula in its tap.

## Settings

Each key resolves through three layers, highest precedence first:

1. **Environment variable** — `DEV_PLANS_REPO`, `DEV_KNOWLEDGE_REPO`,
   `DEV_DEPLOYMENT_FORMULA`, `DEV_CONTAINER_ENGINE`, `DEV_DEFAULT_ORG`,
   `DEV_ENGINE_RESOURCES`, `DEV_LIFECYCLE_RUNNER`.
2. **User file** — `~/.config/dev/config.yml` (or
   `$XDG_CONFIG_HOME/dev/config.yml`).
3. **System file** — `<brew prefix>/etc/dev/config.yml`, installed by the
   org's deployment formula.

A missing file is an empty layer. A key unset everywhere turns its feature
off.

| Key | Meaning |
|---|---|
| `plans_repo` | `owner/repo` for `dev plan --org`. |
| `knowledge_repo` | `owner/repo` of the org learnings repo. |
| `deployment_formula` | The formula `dev up` upgrades, e.g. `d3mlabs/d3mlabs/dev`. |
| `container_engine` | `docker` to use bare docker with whatever daemon the CLI's context reaches, instead of the engine dev provisions. |
| `engine_resources` | `enforce` (default) fails a containerized command on an engine smaller than the repo's `engine:` hint; `warn` prints it and continues. |
| `default_org` | The org a bare `dev clone <repo>` expands under. |
| `lifecycle.runner` | The runner label a lifecycle verb dispatches to when this machine is not the build's environment. |

Manage the user file with `dev config`:

```bash
dev config list              # every key, its value, and which layer set it
dev config get plans_repo    # exit 1 when unset
dev config set default_org d3mlabs
```

## Two formulas

| Formula | Contents |
|---|---|
| `d3mlabs/d3mlabs/dev-core` | The tool: `bin`, `lib`, `share`, `VERSION`, plus the tools dev shells out to (git, gh, ruby, shadowenv). No org content. |
| `<org>/<tap>/dev` | The org's deployment: `depends_on dev-core`, plus a `config.yml` and an optional `Brewfile` installed into `<prefix>/etc/dev/`. |

`brew install d3mlabs/d3mlabs/dev` is the reference deployment; another org
publishes `acme/tap/dev` with the same structure and its own payload.
Formula names are unique per tap, so every org's install line has the same
shape.

Three ways to consume:

- **Org deployment** — `brew install <org>/<tap>/dev`. The org changes its
  config or tooling list by shipping a new formula revision; every machine
  picks it up on its next `dev up`.
- **Individual** — `brew install d3mlabs/d3mlabs/dev-core`, then `dev
  config set` the keys you need.
- **CI / fleet** — set the environment variables in the pipeline or MDM
  profile. They override both files.

### Writing a deployment formula

The d3mlabs formula is the template: `depends_on "d3mlabs/d3mlabs/dev-core"`,
`url` pointing at the `dev-<version>.zip` asset of a dev release, and the
payload installed with `pkgetc.install` so brew preserves local edits
across upgrades. The payload lives in this repo under
[`deploy/d3mlabs/`](../deploy/d3mlabs/).

Two rules:

- `caveats` tells the user to run `dev up`. Installing alone converges
  nothing.
- Never run `brew bundle` or `dev up` from `post_install`. A brew command
  inside a brew install deadlocks on brew's lock.

`config.yml` must name the formula itself under `deployment_formula`; that
is how `dev up` knows what to upgrade.

## Host tooling

An org's `Brewfile`, installed beside `config.yml`, lists tools every
developer machine needs regardless of project. What one project's jobs
need — an agent CLI, say — is that project's own dependency, not the
org's. On every `dev up`, before project provisioning, dev:

1. runs `brew update`;
2. upgrades one formula: the `deployment_formula` setting when set, else
   `dev-core` when brew installed it, else nothing (a source checkout);
3. runs `brew bundle install` against the Brewfile when one exists.

The step is warn-only: offline machines and failed upgrades never block
project provisioning. There is no throttle beyond brew's own
`HOMEBREW_AUTO_UPDATE_SECS`. A deployment fix therefore reaches every
machine on its next `dev up`.

A system `config.yml` that does not set `deployment_formula` draws a
warning on every `dev up`: dev has a deployment but cannot name what to
upgrade.

What goes where:

- `dev-core`'s `depends_on` lists what dev itself needs.
- The Brewfile lists what the org wants beyond that.
- A tool one project needs goes in that project's `dependencies.rb`.

ai-flow is not part of dev's deployment. The d3mlabs Brewfile lists no
agent CLI; ai-flow declares `cursor-cli` in its own `dependencies.rb`,
and its runner roles — the labels, the runner group, the pinned
workflows, the `ai-agent` job identity — in its own `dev.yml`. A host
becomes an agent host by `dev runner register --org --role agent` from
an ai-flow checkout; which ai-flow its jobs run is the adopting
project's lock to say, installed by the job's own `dev up`
([Runners](runners.md#what-a-slot-runs)). No setting, Brewfile line or
builtin role in dev names ai-flow; the build host is dev's one builtin
role.

One Brewfile serves both platforms. Homebrew installs a cask that declares
Linux support into the Linuxbrew prefix and skips one that requires macOS
with a warning. Private taps work through `tap` entries; `gh auth login`
must precede `dev up` in that case.

The step runs for the brew prefix's owner only. On a Linux build host that
is the runner user, so the operator's `dev up` there skips it: the jobs
converge it on their next run. In a checkout the skip is silent; outside
one, the summary line says the layer was skipped and whose it is. By
hand, when a job cannot wait, it is `dev up` as the prefix's owner
outside any checkout — `sudo -iu runner dev up`, with the owner's name
(`dev runner status` prints the command when the host is behind); `dev
up` is the upgrade, so there is no `brew upgrade` to type. A checkout's
own pins are the other half: the operator's `dev up` there installs them
through the runner user's brew with one password prompt. See
[Runners](runners.md#linux-the-runner-user).

## dev is live infrastructure

Projects declare no dev version. Every machine runs the latest release from
the tap, and a release keeps reading every project artifact its
predecessors wrote. The build container follows the same rule: the image
contains the toolchain and no dev; the container installs dev at the host's
version on first use. Design notes:
[ADR-0001](DECISIONS.md#adr-0001--dev-is-live-infrastructure).

The contract runs forward as well as back: a `dev.yml` written for the
latest release still `dev up`s under the dev a host has not upgraded yet,
because the one half that grows a grammar, `targets:`, is refused by the
verbs that need it rather than at load ([dev.yml is read by older
devs](dev-yml.md#devyml-is-read-by-older-devs)). The same rule is what
lets dev develop itself: inside dev's own checkout the installed dev `dev
up`s the checkout's lock, then hands every verb to the checkout's `bin/dev`
([Inside dev's own checkout, dev is the
checkout](cli.md#inside-devs-own-checkout-dev-is-the-checkout)).

A tool deployed through its own gh channel is live the same way, one
release at a time: `dev release` cuts an immutable release, `dev deploy
gh` moves the series head to it, and every lock pinning that series
takes the head at its next `dev up` ([Lifecycle: the channel contract](lifecycle.md#the-channel-contract)).
dev's formula is the brew channel's head; a deployed tool's series tag
is the gh channel's.

## Migrating from the monolithic formula

Installs from before the core/deployment split:
`brew uninstall dev && brew install d3mlabs/d3mlabs/dev`.
