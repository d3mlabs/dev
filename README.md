# dev
[![codecov](https://codecov.io/gh/d3mlabs/dev/branch/main/graph/badge.svg)](https://codecov.io/gh/d3mlabs/dev)

Global CLI tool for d3mlabs projects. Discovers `dev.yml` in your git repos and executes declared commands like `dev up`, `dev build`, `dev test`, etc.

## Installation

```bash
brew install d3mlabs/d3mlabs/dev   # your org's <org>/<tap>/dev; `d3mlabs/d3mlabs/dev-core` for the org-blank tool
gh auth login                      # dev pulls gated assets and syncs plans through your gh auth
dev up                             # converges host tooling + installs the shell hooks; open a new shell after
```

Then per project: `dev clone <repo>` → `dev up`.

That is the whole fresh-machine story. The formula carries every tool dev itself shells out to (git, gh, ruby, rbenv, ruby-build, shadowenv), and `dev up` provisions the rest — the project's Ruby, the shadowenv and `dev cd` shell hooks, the org's host tooling. Orgs install their deployment formula (tool + org configuration in one command); individuals without an org install `dev-core` and write their own config — see [Org configuration & deployment](#org-configuration--deployment).

**Windows** is the same story inside WSL2. Once, from an elevated PowerShell: `wsl --install -d Ubuntu`, then open Ubuntu and [install Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux). From there the three lines above are identical. The first `dev up` in a containerized repo installs Docker inside the distro (one sudo prompt) and sizes the WSL VM through `%USERPROFILE%\.wslconfig`; when it grows the VM it tells you to run `wsl --shutdown` from Windows and come back — the one restart WSL imposes, and the only step dev cannot do for you. Docker Desktop's WSL integration must be unticked for the distro first; dev refuses to fight it and says so. See [The container engine](#the-container-engine-per-user).

Some projects need more than the formula ships — Docker for containerized builds, `zstd` for `.tar.zst` engine archives, 32-bit libs for SteamCMD on Linux. Those are that project's facts, declared in its `dependencies.rb` or documented in its README; a missing one surfaces from `dev up` with the fix. (Docker on Linux/WSL is the exception dev converges itself, since the engine is dev's.)

## Usage

```bash
dev                       # list every command available here (same as `dev help`)
dev <command> [args...]   # extra args are forwarded to the command
```

dev walks up from your current directory to the git repo root and reads the `dev.yml` there. Every command is one of two kinds: a **project command** declared in that `dev.yml` (`dev test`, `dev build`, …), or a **builtin** that ships with dev. A project may declare a command on a builtin's name (typically `up`); the builtin body runs first, then the project's `run:` — a hardcoded `super()`.

Commands form a **tree**, and `dev` itself is its root: any command may have subcommands (`dev deps path`, `dev runner status`, a project's `dev test unit`). Resolution follows argv one token at a time from the root — a token naming a child descends; the first token that doesn't is where the args begin. A command with nothing of its own to run prints its usage when invoked bare (so bare `dev` lists everything, `dev deps` lists its verbs (`update`, `install`, `check`, `path`), `dev plan` lists the plan verbs); `dev help <path…>` prints the same view for any node. Commands with subcommands show a trailing `…` in the listing, and Tab completion follows the same tree (`dev plan <Tab>` offers `new link pull push status init`) once the [shell hook](#shell-hook-install) is installed.

### Built-in commands

Grouped as `dev help` lists them. **Scope** says where the command works: *anywhere* needs no `dev.yml`; *project* needs one; *gated* exists only when the `dev.yml` declares the named config.

**Lifecycle** — provisioning, dependency state, and machine enrollment:

| Command | Scope | Purpose | Details |
|---|---|---|---|
| `dev up` | project, or anywhere (host layer only) | Converge host tooling, install locked deps, bring the build container up, run the project's `up:`; `--no-cache` does the project half from nothing | [Dependency commands](#dependency-commands), [The cold run](#the-cold-run-dev-up---no-cache) |
| `dev down` | gated: `build.container` | Stop this checkout's service dependencies (the build container), and the engine if nothing else uses it | [Engine & container lifecycle](#engine--container-lifecycle) |
| `dev deps update` | project | Resolve `dependencies.rb` and write the lockfiles (≈ `bundle update`) | [Dependency commands](#dependency-commands) |
| `dev deps install` | project | Install locked deps on this machine, optionally narrowed by `--group`/`--except`/`--integration`; `--pinned-taps` pins brew's taps at the lock's commits (≈ `bundle install`) | [Dependency commands](#dependency-commands) |
| `dev deps check` | project | Report dependency staleness (manifest vs lockfiles vs installed); exits non-zero when stale (≈ `bundle check`) | [Dependency commands](#dependency-commands) |
| `dev deps path <integration> <name> [<platform>]` | project | Print a locked artifact's absolute path | [Dependency commands](#dependency-commands) |
| `dev runner register\|status` | anywhere | Enroll or inspect this host as a self-hosted runner | [dev runner](#dev-runner--enroll-a-host-as-a-self-hosted-runner) |
| `dev engine up\|down [--force]\|status` | anywhere | Start, stop, or inspect the per-user container engine (colima VM / dockerd) | [The container engine](#the-container-engine-per-user) |
| `dev container up\|down\|reset\|tag\|status` | gated: `build.container` | This checkout's build image and container: resolve and start, stop warm, remove, print the tag, report | [Engine & container lifecycle](#engine--container-lifecycle) |

**Development flow** — navigation, settings, agent workflow, housekeeping:

| Command | Scope | Purpose | Details |
|---|---|---|---|
| `dev cd <repo>` | anywhere | Jump to a checkout under `$DEV_CD_ROOT` by fuzzy name, with Tab completion | [dev cd](#dev-cd--jump-between-checkouts) |
| `dev clone [<org>/]<repo>` | anywhere | Clone via `gh` into the canonical checkout path and land there | [dev clone](#dev-clone--clone-into-the-canonical-layout) |
| `dev config list\|get <key>\|set <key> <value>` | anywhere | Manage dev's layered settings | [Org configuration & deployment](#org-configuration--deployment) |
| `dev cred get <namespace> <key>` | anywhere | Resolve a stored credential and print it | [dev cred](#dev-cred--resolve-a-credential) |
| `dev plan new\|link\|pull\|push\|status\|init` | anywhere | Sync Cursor plans with GitHub issues | [dev plan](#dev-plan--sync-plans-with-github-issues) |
| `dev learnings sync\|status\|invariants\|init` | anywhere | The org learnings read path | [dev learnings](#dev-learnings) |
| `dev cache gc [--keep N] [--tool-caches]` | project | Reclaim host caches dev owns | [`dev cache gc`](#dev-cache-gc) |
| `dev version` (`--version`) | anywhere | Print this dev's version, one line | [Inside the container](#inside-the-container) |
| `dev help` | anywhere | Show usage: project commands plus the builtins available here | — |

### Errors

- No git repo above the current directory: `dev: no git repo (with dev.yml) found above <path>`
- A git repo without a `dev.yml` (and the command is not an *anywhere* builtin): `dev: found git repo at <path> but no dev.yml there`
- Unknown command: `dev: Command '<name>' not found` (the full path for an unknown subcommand, e.g. `'deps bogus'`), with a pointer to `dev --help`

## dev.yml convention

Each repo that wants to support `dev` should have a `dev.yml` at its git root:

```yaml
name: myproject

commands:
  up:
    desc: Setup dev environment
    run: ./bin/setup.rb
  build:
    desc: Build the project
    run: ./bin/build.sh
  test:
    desc: Run tests
    run: ./bin/test.sh
  console:
    desc: Start Ruby console
    run: ./bin/console
    repl: true
  db:                          # no run: bare `dev db` prints its usage
    desc: Database chores
    commands:
      reset:
        desc: Reset the dev database
        run: ./bin/db_reset.sh
```

- `name`: Display name for the repo (used in help output).
- `commands`: Map of command names to specs. A spec declares `run`, `commands`, or both — never neither.
  - `desc`: Short description (shown in `dev` / `dev --help`).
  - `run`: Shell command to execute (from the repo root). Any extra args passed to `dev <cmd> [args...]` are forwarded to this command.
  - `commands`: *(optional)* Nested map of subcommand specs, same shape, any depth. `dev <cmd> <sub> [args...]` runs the child. With `run` beside it, bare `dev <cmd>` runs `run` and a first arg that isn't a child's name is forwarded to it (`dev test --fast`; `dev help <cmd>` shows both forms). Without `run`, bare `dev <cmd>` prints the usage and an unknown first arg is an error. A child cannot be named `help`, and a command with subcommands cannot be a `repl`.
  - `repl`: *(optional, default `false`)* When `true`, the command execs directly without a status footer. Use this for long-running interactive sessions like consoles and REPLs where a trailing `✓ Done` doesn't make sense.
  - `container`: *(optional, default `true` when `build.container` is configured)* When `false`, the command runs on the host (via `shadowenv exec`) instead of inside the build container. Use for host-side commands like provisioning (`up`) or deploying.
  - `hidden`: *(optional, default `false`)* When `true`, the command is still callable (`dev <cmd>`) but omitted from `dev` / `dev --help` output. Use for internal plumbing — e.g. a `build` primitive that an intent command (`test`, `release`) calls but that developers shouldn't invoke directly.
- A project spec on a **builtin's name** merges with it: `run` on a builtin is the `super()` override above; subcommands always merge child by child (new children are added, same-named children override — `deps:`, `cache:`, `runner:` accept new verbs this way); `up:` with only `commands:` keeps bare `dev up` as the builtin and adds the children.

## Adoption model

dev's feature set is three independent opt-ins; a repo takes whichever rungs it needs, in any combination:

1. **Command running** — add a `dev.yml` with a `commands:` map. That alone gets you `dev up` / `dev test` / etc. with the standard UI, from anywhere in the repo. dev does not touch your toolchain or dependencies; your scripts keep doing whatever they did before.
2. **Toolchain provisioning** — add a `dependencies.rb` with just a `ruby` directive (see [Ruby version resolution](#ruby-version-resolution)). dev provisions that exact Ruby (rbenv + shadowenv) and every `dev <cmd>` runs under it. This does *not* hand your Gemfile to dev — a hand-written Gemfile stays yours, managed by plain bundler.
3. **Dependency management** — declare gems, brew formulae, engine artifacts, etc. in `dependencies.rb`. `dev deps update` locks them and `dev up` installs them; for `gem()` declarations dev generates and owns the `Gemfile`.

A gem repo typically stops at rungs 1–2 (commands + a pinned Ruby, hand-written gemspec/Gemfile); an app repo usually takes all three.

## How provisioning works

### Ruby version resolution

A project declares its Ruby toolchain in exactly one place: the `ruby "x.y.z"` directive in `dependencies.rb` (see [Dependency management](#dependency-management)). The toolchain is a project dependency, so it lives in the dependency manifest — even when nothing else is declared there. A ruby-only manifest is the minimal form and engages nothing else (no Gemfile generation, no lockfiles, no other integrations):

```ruby
require "dev/deps"

Dev::Deps.define do
  ruby "4.0.6"
end
```

Repos with no `dependencies.rb` (or no `ruby` directive) fall back to the machine's Homebrew Ruby. A `ruby:` key in `dev.yml` is no longer supported; dev refuses to run and points at the `dependencies.rb` migration.

On `dev up`, dev provisions the declared version through rbenv (installing it if needed) and generates two artifacts at the repo root:

- **`.shadowenv.d/510_ruby.lisp`** — the per-project environment. Contains machine-specific absolute paths; always gitignored.
- **`.ruby-version`** — the standard rbenv pin, so everything that is not shadowenv-aware (a plain rbenv shell, RubyMine's SDK detection, Bundler's `ruby file:`, GitHub's setup-ruby) agrees with dev.

**Commit `.ruby-version` when the project declares its Ruby.** It is deterministic generated output — same idea as a lockfile — and it is exactly what contributors without dev consume. Do not commit it for fallback-Ruby repos: there it reflects whatever Ruby the machine happens to have.

Keep the file a bare version string. rbenv only reads the first word, but other consumers (setup-ruby, Bundler, editors) parse the file strictly, so comments would break them. There is no drift risk in the other direction either: `dev up` rewrites the file from the declared version every run, so a hand edit never survives — to change the Ruby, edit `dependencies.rb`, run `dev deps update`, then `dev up`.

### Supported shells

All dev shell RC hooks — shadowenv activation (`eval "$(shadowenv init <shell>)"`) and the `dev cd` wrapper + completers — are installed automatically and idempotently by `dev up` (and by `dev cd` itself) for **zsh, bash, and fish** (`~/.zshrc`, `~/.bash_profile` or `~/.bashrc`, `~/.config/fish/config.fish`); see [Shell hook install](#shell-hook-install). Other shells are unsupported for hooks: `dev` project commands still run, but there is no env activation and no `dev cd`.

**Formula maintainers:** `dev-core` carries `depends_on "shadowenv"` so developers get shadowenv with the tool. Formulas must never edit shell RCs — dev installs its hooks itself on its own command paths (`dev up`, `dev cd`).

## Org configuration & deployment

dev's source hardcodes no org content — every org-specific fact enters through **settings**, resolved per key with gitconfig-style layering (`Dev::Settings`):

1. **ENV var** — `DEV_PLANS_REPO`, `DEV_KNOWLEDGE_REPO`, `DEV_DEPLOYMENT_FORMULA`, `DEV_CONTAINER_ENGINE`. Highest precedence.
2. **User file** — `~/.config/dev/config.yml` (or `$XDG_CONFIG_HOME/dev/config.yml`).
3. **System file** — `$(brew --prefix)/etc/dev/config.yml`, shipped by an org's deployment formula.

Missing files are empty layers; a key set in the user file wins over the system file. The keys:

```yaml
plans_repo: d3mlabs/plans              # org-wide plans repo (dev plan --org)
knowledge_repo: d3mlabs/knowledge      # org learnings sync source
deployment_formula: d3mlabs/d3mlabs/dev  # the formula `dev up` self-updates (the deployment names itself)
container_engine: docker               # per-user opt-out from the host's engine ("docker" = bare dockerd; unset = colima on macOS, bare dockerd elsewhere)
engine_resources: warn                 # "enforce" (default) fails a build on an engine below the repo's resources hint; "warn" prints it and carries on
default_org: d3mlabs                   # the org a bare `dev clone <repo>` expands under (unset = explicit <org>/<repo> only)
```

Leaving a nilable key unset turns its feature off (`plans_repo` is only required by `dev plan --org`). Manage the user file with `dev config` instead of hand-editing YAML: `list` shows every known key with its resolved value and source layer (`env` / `user` / `system` / unset) — the settings debugging tool; `get <key>` prints the resolved value (exit 1 when unset); `set <key> <value>` writes the user file, creating it if missing. Known keys only; global, works without a `dev.yml`. The tool ships as two kinds of formula (the Debian core-package/config-package split, applied to a tap):

- **`d3mlabs/d3mlabs/dev-core`** — the generic tool, org-blank: the build payload plus the tools dev itself shells out to (git, gh, ruby, rbenv, ruby-build, shadowenv). It ships no org content.
- **A deployment formula named `dev` in each org's tap** — `depends_on "d3mlabs/d3mlabs/dev-core"` plus the org's payload installed into the prefix's `etc/dev/` (pkgetc — brew preserves locally-modified etc files across upgrades): a `config.yml` with the org's keys (including `deployment_formula`, its own name — that's how `dev up` knows what to upgrade) and an optional `Brewfile` with the org's host tooling (see [Host tooling: the Brewfile contract](#host-tooling-the-brewfile-contract)). Formula names only need to be unique within a tap, so every org's install is the same shape: `brew install d3mlabs/d3mlabs/dev` is the reference deployment, and an adopting org publishes `acme/tap/dev` with identical structure and its own payload.

  Two authoring rules for that formula: print a "run `dev up` to converge this machine" pointer in `caveats` (the fresh-box signal — install alone converges nothing), and never converge from `post_install` — running `brew bundle` inside a brew install is a nested brew invocation that deadlocks on brew's own lock. Converging is `dev up`'s job, on the user's side of the install boundary.

Three consumption stories:

- **Org deployment (recommended):** `brew install <org>/<tap>/dev` — one command installs tool + identity, and the org evolves its config and tooling list by shipping a new deployment formula revision; every machine picks it up on its next `dev up`.
- **Individual / handrolled:** `brew install d3mlabs/d3mlabs/dev-core`, then `dev config set <key> <value>` for the keys you need — no org involvement, useful for personal machines or orgs without a tap. No Brewfile means the host tooling step self-skips.
- **CI / fleet:** set the ENV vars in the pipeline or MDM profile — no files needed, and they override both file layers.

Installs predating the split (when `dev` was a monolithic tool+config formula) migrate with a hard cut: `brew uninstall dev && brew install d3mlabs/d3mlabs/dev`.

## dev cd — jump between checkouts

`dev cd <repo>` jumps to a local checkout under your search root by short name, with fuzzy matching and Tab completion:

```bash
dev cd myrepo              # unique fuzzy / substring match → cd there
dev cd d3mlabs/myrepo      # explicit org/repo when names collide
dev cd d3m/d               # fuzzy each side of / → e.g. d3mlabs/dev
dev cd myr<TAB>            # interactive complete: list matches, select or refine
dev cd <TAB>               # empty prefix → list all candidates
```

The search root is `$DEV_CD_ROOT`, defaulting to `~/src` with the conventional `~/src/github.com/<org>/<repo>` layout. If your checkouts live elsewhere, set the override in your shell RC (or the current session) before calling `dev cd`:

```bash
export DEV_CD_ROOT=/path/to/checkouts
```

Only git repos count as candidates (directories with a `.git` entry — a `.git` file from a worktree checkout works too); plain folders are skipped. The query is a right-anchored path suffix matched per segment: `dev` matches the leaf, `d3mlabs/dev` the org and leaf, `bitbucket.org/d3mlabs/dev` the host too — a more explicit path always works. On an ambiguous query, `dev cd` lists the candidates (each at the shortest depth that makes it unique, capped at 10) and exits non-zero; refine the query or press Tab to browse all matches. On no match it errors clearly.

## dev clone — clone into the canonical layout

`dev clone [<org>/]<repo>` clones a GitHub repo (via your `gh` auth — no credentials of dev's own) into the canonical checkout path under the same search root `dev cd` walks — `$DEV_CD_ROOT/github.com/<org>/<repo>`, default `~/src` — and lands your shell in the fresh checkout through the same wrapper:

```bash
dev clone myrepo           # bare name expands under the default_org setting → ~/src/github.com/<default_org>/myrepo
dev clone acme/widget      # explicit org
```

A bare `<repo>` needs the `default_org` key in `~/.config/dev/config.yml` (or `DEV_DEFAULT_ORG`); without it, dev asks for an explicit `<org>/<repo>` — dev is public and hardcodes no org.

It is clone-only by design — no automatic `dev up`. Provisioning stays a deliberate second step, because a first `dev up` is where credential prompts happen and you should see them coming. The fresh-machine story is three commands: `brew install d3mlabs/d3mlabs/dev` → `dev clone <repo>` → `dev up`.

If the canonical destination already exists, `dev clone` errors and points you at `dev cd`. Without the shell wrapper active (e.g. the very first dev command on a fresh machine), the clone still happens; dev installs the hook for next time and prints the destination instead of jumping there.

### Shell hook install

`dev cd` and the landing half of `dev clone` need a small shell wrapper — a Ruby child process cannot change your shell's directory. dev installs the wrapper function and Tab completers into your shell RC automatically and idempotently: on `dev up` in any project, and on `dev cd` / a hook-less `dev clone` themselves (so a first use self-heals the hook; open a new shell after the install hint). The snippet is marker-guarded (`# dev cd + clone + completion (added by dev)`) next to the shadowenv one, and re-runs never duplicate it; when the snippet itself evolves, the marker changes with it and the next ensure appends the updated wrapper, whose later definition wins.

Tab completion is registered per shell: zsh gets a navigable menu-select list scoped to the `dev` command only (your other commands' completion is untouched; registration is skipped quietly if your zshrc never runs `compinit`), bash fills `COMPREPLY` directly, and fish registers a standard pager completion (fish applies its own filtering, so fuzzy tokens may only complete literally there). For `dev cd <repo>`, completion fills the argument only — it never runs the `cd` for you — and inserts `org/repo` (or deeper) forms when a short name would collide. Everywhere else it completes command names down the tree: `dev <Tab>` offers the commands available here (project ones included), `dev plan <Tab>` a group's children, backed by the hidden `dev complete <words…>` plumbing.

Because the wrapper runs `builtin cd` in your interactive shell, shadowenv activation after `dev cd` behaves exactly like a manual `cd`: if the shadowenv hook is in your RC (see above), the project env loads; if it's missing, `dev cd` still changes directory but no env activates — same as plain `cd`.

## dev cred — resolve a credential

`dev cred get <namespace> <key>` resolves a credential through the provider chain (ENV → keychain → file → prompt) and prints it. A non-interactive miss errors with `gh secret set` guidance. It mirrors `dev deps path` for shell consumers (e.g. a staging sync script), so scripts never embed lookup logic of their own. Global: works without a `dev.yml`.

## dev runner — enroll a host as a self-hosted runner

A machine-setup verb: rare, admin-flavored, human-run — and declared nowhere. Enrollment identity is a machine fact, not a repo one, so there is no `runner:` block in dev.yml (the key is retired and warns): scope and labels compose from flags, with derived defaults covering the common enrollments.

```bash
dev runner register                     # repo scope; label = the repo name
dev runner register --labels ue-engine  # repo scope, custom roles
dev runner register --org --ai-flow     # org agent host: the full ai-flow label set
dev runner register --org --labels ai-build   # org custom pool (e.g. a beefy build box)
dev runner status                       # THIS machine's enrollments + host facts
```

**Demand and supply.** Workflows demand labels (`runs-on: [self-hosted, <label>]`); enrollments supply them. GitHub routes a job to any online runner visible to the repo (its own repo-scoped runners plus the org's) whose labels cover the demand — first available wins, with **no repo-beats-org priority**. So an org agent host and a repo-scoped `ai-build` box sharing a label is capacity pooling; a strict partition is expressed through label sets, never through scope. Three vocabularies exist today: a repo's own CI label, **its repo name as GitHub spells it, lowercased** (`d3mlabs/cellbound-3d` → `cellbound-3d`; dashes stay — labels allow them, and a repo-scoped runner is that repo's object, so the workflows targeting it read the same name they live under; dev.yml `name:` is the package identity and may differ); special fleets' explicit `--labels` (e.g. unreal-engine's `ue-engine` / `macos,ue-editor` boxes); and the **ai-flow vocabulary** (`ai-ask ai-edit ai-split ai-build ai-learn`) — defined by ai-flow's reusable workflow (one label per slash command), mirrored here as `LabelContracts::AI_FLOW_LABELS` behind `--ai-flow`.

**`dev runner register`** converges, then enrolls. First, when the enclosing checkout declares `build.container`, the **engine** this host will build in: the same step as `dev up`'s, for the invoking user (the runner runs as that user, as GitHub's `config.sh`/`svc.sh` do), sized from this repo's `resources:` hint and ratcheting across the repos a host serves — colima on macOS, dockerd-in-distro and the `.wslconfig` ratchet on WSL2, dockerd on Linux (see [The container engine](#the-container-engine-per-user)). Then the **label contracts**: a capability label is not just routing metadata — it names an obligation the host must satisfy, and register converges the (possibly empty) requirements of every label being advertised. A bare target-host label (e.g. a gamebox) converges nothing; the agent capability labels (`ai-build`, `ai-learn`) mark the box an **agent host** and carry the **agent host bootstrap** (below). Then the enrollment: register looks for an existing enrollment at the target scope (every `~/actions-runner-*/.runner` on the host — dir names never matter) and **amends its labels in place on GitHub** instead of re-enrolling, so re-running is both the idempotent no-op and the drift repair; only a scope nothing serves gets the full ceremony (actions-runner download, registration-token mint via your `gh` auth, `config.sh --unattended --replace`, service install — itself idempotent, including across scopes: a repo-scoped runner re-registered `--org` deregisters at its old scope first). Enrollment state is **inspected, never recorded**: labels live on GitHub, the scope in the runner dir's own `.runner` record — nothing in dev.yml, Settings, or any inventory file. Flags: `--org`, `--repo`, `--ai-flow`, and `--labels`/`--dir`/`--name` identity overrides; `--agent-user` overrides the `ai-agent` run-as default. `--org` needs no project checkout; bare register does (it sizes the engine from `build.container` and reads the repo name via `gh`; `--repo` moves the derived label with it).

The **agent host bootstrap** is host-singular, idempotent, and admin-prompting (macOS-only today). Every fact is inspectable and none is recorded — there is no record file. It converges: the hidden non-admin agent user with its own home; the cooperative `ai` group with both identities enrolled; the one-way sudoers edge (runner user → agent, `NOPASSWD:SETENV`, staged and `visudo -c` validated before landing root-owned 0440); the shared data root with the one-off `~/.dev` migration (below); the agent's own container engine when the enrolling checkout declares `build.container` (colima via brew, the agent's `container_engine: colima` record, its VM sized from the repo's `resources:` hint); and after enrollment, the `_work` job-checkout tree as a cooperative group space plus the runner service env — `Umask` 002 and `AI_FLOW_AGENT_USER`, the single record of "jobs landing here execute as X".

**`dev runner status`** is the inspect-only half, and it is the *machine's* view, not any repo's: every discovered enrollment (scope and name from its own `.runner` record — works offline), each one's labels read from GitHub (their single home; unknown when offline, flagged when the runner is gone server-side), the re-derived reality of each agent-labeled enrollment's contract (agent user, group memberships, sudoers edge, `_work` grant, shared root, agent engine where required), and host tooling (`brew bundle check` against the org Brewfile, self-skipping when none ships).

### The data root (shared on agent hosts)

Dev-managed artifacts (engine trees, the download cache, steam depots — everything configured under `~/.dev`) live at the **data root**, resolved per invocation: an explicit `DEV_DATA_ROOT` wins; otherwise the shared root (`/Users/Shared/dev`) when it exists; otherwise `~/.dev`. On an agent host the register bootstrap provisions the shared root (human-owned, group `ai`, setgid group-writable, world-readable) and migrates existing `~/.dev` artifact trees into it by rename — so one engine tree serves both identities, the same way `/opt/homebrew` already does. Presence is the record: no config key, no record file. Mutable per-user state (`~/.dev/state`) never migrates and never shares.

## Child script UI

Dev uses `Kernel.exec` to replace itself with the child command. This gives the child full, direct terminal access — no pipes, no PTY, no output interception.

Dev prints a colored header (the command name) before exec-ing. For non-repl commands, a shell wrapper runs after the child exits and prints `✓ Done` or `✗ Failed` based on the exit code. Commands marked `repl: true` exec directly without a wrapper (for interactive sessions like consoles).

### How it works

Ruby child scripts use [Shopify's cli-ui](https://github.com/Shopify/cli-ui) natively for frames, spinners, prompts, and colors. Since the child IS the process (not a subprocess), all CLI::UI features work without compromise — animated spinners, interactive prompts, password inputs, menus.

Shell scripts output plain text. No special markers or protocol needed.

### Running subcommands from child scripts

Since the child process has full terminal access, `system()` is the simplest and best default for running subcommands — the subprocess inherits the TTY, so colors, prompts, and interactive output all work.

Use `Open3.capture3` instead when running a subcommand **inside a `CLI::UI::Spinner`**. The spinner uses StdoutRouter to capture output while it animates; `system()` writes directly to the terminal file descriptor (bypassing StdoutRouter), which causes output to leak past the spinner and produce garbled text. `capture3` redirects the subprocess's stdout to a pipe so the spinner stays clean.

```ruby
# Outside a spinner — system() is fine
system("cmake", "--build", "build")

# Inside a spinner — use capture3 to prevent output leaking
CLI::UI::Spinner.spin("Installing bundler...") do
  out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
  raise "install failed: #{err}" unless status.success?
end
```

### Environment behavior

| | Ruby scripts (with cli-ui) | Shell scripts |
|---|---|---|
| Dev terminal | Full CLI::UI: frames, colors, animated spinners, prompts | Plain text |
| CI (no TTY) | CLI::UI degrades gracefully (no animation, basic formatting) | Plain text |
| Cursor sandbox | Same as dev terminal (use `dev <cmd>` per `.cursor/rules/dev.mdc`) | Plain text |
| Without dev | CLI::UI renders directly to terminal | Plain text |

### Ruby / environment resolution

| | How Ruby resolves |
|---|---|
| Dev terminal | `dev` uses Homebrew Ruby (shell trampoline in `bin/dev`). Child commands get the project's Ruby via `shadowenv exec --`. |
| CI | Docker image provides Ruby. Scripts run directly (not via `dev`). |
| Cursor sandbox | `dev <cmd>` resolves Ruby correctly. `.cursor/rules/dev.mdc` instructs the AI agent to always use `dev <cmd>`. Shell trampolines in child scripts are NOT needed — only `d3mlabs/dev`'s own bin/ scripts need them (bootstrapping: can't use `dev` to run `dev` itself). |

## Dependency management

Dev includes a built-in dependency management system for reproducible builds across ecosystems.

### Lifecycle

Dependencies flow through four stages:

1. **Declare** — list what you need in `dependencies.rb` using the Ruby DSL
2. **Resolve & lock** — `dev deps update` resolves constraints to exact versions and writes lockfiles
3. **Install** — `dev up` installs pinned dependencies from lockfiles (build group first)
4. **Use** — `dev <command>` provisions the project's toolchain environment and runs your command

Lockfiles are the source of truth for stages 3 and 4. After changing `dependencies.rb`, run `dev deps update` to re-resolve before building.

### Lockfiles

Two YAML lockfiles, same format, two purposes:

- **`deps.lock`** — pins every runtime dependency (app + test groups) to exact version + SHA256 integrity hash.
- **`build-deps.lock`** — pins every build dependency (build group). Separate file for CI cache convenience — `hashFiles('build-deps.lock')` as Docker image cache key means runtime dep changes don't invalidate build tooling.

Both files are generated by `dev deps update` and committed to git. Never edit them by hand.

A lock describes what a dependency publishes, never the machine that wrote it. A pin whose version publishes one file carries that file's hash; a pin whose version publishes several platform builds carries a `platforms:` block — every published target with its hash and link — whether the declaration named platforms (ficsit targets) or not (brew bottles: every bottle tag the formula ships, `arm64_tahoe`, `x86_64_linux`, …, read once per formula from brew for tap formulae and from the public formula API for `homebrew/core`). The same `dev deps update` on a Mac and on a Linux box therefore writes the same bytes, and a re-lock that changes no version changes no build image tag.

### Reproducible brew

Brew is a moving registry: `brew install cmake` installs whatever `homebrew/core` has *today*, so a lock that merely records a version has no bite on its own. dev gives it two, one per side of the container boundary:

- **Hosts verify (B).** After every brew install — and when the formula was already present — `dev deps install` reads `brew list --versions` and fails with `VersionMismatchError` unless a keg matches the locked version (brew's own `_1` revision suffix aside). The error carries both remediations, since the two causes need different hands: `dev deps update` when brew's formula moved on and the lock is stale; `brew upgrade <formula>` when the machine is behind the lock. Hosts keep brew in its default API mode — the verification is the contract, not the install path. Casks are not verified (brew reports no stable version for most).
- **Images pin (A).** `dev deps update` records, per formula, the commit its tap was at (`tap_commit`, brew's `tap_git_head` — `homebrew/core` for untapped formulae) and `format`: `bottle` when the formula ships an `x86_64_linux` bottle, `source` when it does not. The build group's brew formulae are installed in one place — `brew install` inside `docker build` ([`bin/docker-install-build-deps.sh`](bin/docker-install-build-deps.sh)) — and brew downloads a prebuilt bottle when one exists for the platform and compiles the formula otherwise; a `source` formula is where an image build goes from minutes to an hour under emulation, or fails on a build dependency. It is one compile per image build (the image is content-addressed on `build-deps.lock`, so the layer rebuilds only when the lock changes), but the moment to know about it is `dev deps update`, while the version is still a choice. `format` is read off the pin's `platforms:` block (see [Lockfiles](#lockfiles)), and `dev deps update` names every `source` formula the image build would install — the build group's brew formulae, as the image's own `dev deps install` selects them, so a formula gated to Macs is never named — right where the lock is written. `dev deps install --pinned-taps` then checks each tap out at its locked commit and runs `brew install` under `HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_AUTO_UPDATE=1`, so two image builds of one lock install one toolchain. The checkout is a **single-commit fetch** (`git fetch --depth 1 origin <commit>` into brew's `Library/Taps` layout — `Dev::Deps::TapPinner`), not a clone of homebrew-core's history, which is the cost that made pinning taps impractical. A lock without tap commits, or one pinning a tap at two commits, fails before anything is pinned, with the `dev deps update` remediation.

The image bootstrap ([`bin/docker-install-build-deps.sh`](bin/docker-install-build-deps.sh)) passes `--pinned-taps` when `DEV_PIN_TAPS=1`. It is opt-in until the single-commit fetch has been measured against a real image build; by default an image build installs through brew's API and verifies the result against the lock exactly as a host does.

### Host tooling: the Brewfile contract

Alongside per-project dependencies, an org converges **host tooling** — the org-invariant tools every developer machine needs regardless of which projects it serves (an editor-class agent CLI, say). The principle is **brew converges brew**: dev never re-implements host tooling convergence, it only *triggers* brew's — the same way it triggers bundler for gems.

- **The list lives in the deployment formula's `Brewfile`**, installed into `$(brew --prefix)/etc/dev/` beside `config.yml`. Convention, not configuration: file present means `dev up` runs `brew bundle install` against it; absent (tapless individual, CI) means the step self-skips. No settings key, no fetch, no cache — the file is local, delivered by packaging.
- **Disjoint sets:** `dev-core`'s `depends_on` answers "what does the tool need" (git, gh, ruby, rbenv, ruby-build, shadowenv); the Brewfile answers "what does the org want beyond that". No entry ever appears in both; if dev drops a dep the org still wants, that fact migrates to the Brewfile. Tools that belong to one piece of software stay in that repo's own `dependencies.rb`.
- **Private taps:** Brewfiles natively support `tap` entries, including private taps over authenticated git — sensitive tooling goes in a private tap the Brewfile references. `gh auth login` must precede `dev up` in that case (the failure mode is brew's own clear git-auth error).
- **Trust model:** a Brewfile is brew-evaluated Ruby DSL, so converging it executes org-authored code — the same trust already granted by installing the org's deployment formula. dev adds no new trust surface: the file lives in the brew prefix at a fixed path, never a user-supplied one, and brew's tap-trust gate covers formulas from untrusted taps.

On every `dev up`, before project provisioning, `Dev::HostService` converges the host tooling: **`brew update`**, a **scoped `brew upgrade` of the `deployment_formula`** the deployment named in its own `config.yml` (falling back to `dev-core` for tapless individuals; skipped entirely for source checkouts — never a blanket `brew upgrade` of unrelated packages), then **`brew bundle install`** against the Brewfile when one exists. dev adds no throttle of its own — the no-op steps are sub-second, and brew's `HOMEBREW_AUTO_UPDATE_SECS` remains the only network rate limiter (tune it through brew) — so a deployment fix propagates on the very next `dev up`. The whole layer is warn-only: offline machines and failed upgrades never block project provisioning. Upgrading is symmetric: the org edits one line in its tap's Brewfile (or ships a config change via formula revision) and every machine converges on its next `dev up` — no brew vocabulary required, though a direct `brew upgrade` keeps working for users who prefer it.

### dev is live infrastructure

Projects declare no dev version: every machine runs the latest release from the tap, converging on `dev up` (above), and a release keeps reading every project artifact its predecessors wrote (`dev.yml`, `dependencies.rb`, the lockfiles — including the legacy flat lock format). The build container follows the same rule: an image build installs its toolchain with `dev deps install --group build --integration brew` from `build-deps.lock` and then uninstalls dev-core ([`bin/docker-install-build-deps.sh`](bin/docker-install-build-deps.sh)), so the image contains the toolchain and no dev; what the container then needs installs inside it, where it is consumed ([Inside the container](#inside-the-container)), and a hosted job with no orchestrating host provisions dev at latest, like a fresh workstation ([Hosted jobs](#hosted-jobs-container-image)). Why it is this way, and what was rejected, is [ADR-0001](docs/DECISIONS.md#adr-0001--dev-is-live-infrastructure), [ADR-0002](docs/DECISIONS.md#adr-0002--dependencies-install-where-they-are-consumed) and [ADR-0003](docs/DECISIONS.md#adr-0003--a-brew-lock-has-bite-on-both-sides).

### dependencies.rb

Declare dependencies using a Ruby DSL:

```ruby
require "dev/deps"

Dev::Deps.define do
  ruby "4.0.6" # the project's Ruby toolchain; dev provisions it (rbenv + shadowenv)
  python "3.12" # optional Python toolchain; dev provisions the interpreter + a project .venv
  gem "cli-ui"
  tap "d3mlabs/d3mlabs"

  group :build do
    brew "cmake"
    brew "llvm", version: "22"
    env :ci do
      brew "ruby"
    end
  end

  group :app do
    cmake "boost",
          url: "https://example.com/boost-1.90.0.tar.gz",
          tag: "boost-1.90.0"
    cmake "cereal", github: "USCiLab/cereal", tag: "v1.3.2"
  end

  group :test do
    cmake "googletest", github: "google", tag: "v1.17.0",
          targets: ["gtest", "gmock"]
    luarocks "luaunit", ">=3.5"
  end

  # Python packages install into the project .venv (needs a `python` directive).
  # Heavy, host-specific toolchains gate with `host:` so they only land where used.
  group :anatomy, host: :darwin do
    pip "totalsegmentator", ">=2.0"
  end
end
```

### Dependency axes

Four orthogonal axes scope a declaration; each answers a different question:

- **`group`** — *purpose* (`:app`, `:test`, `:build`, `:game`, `:editor`, …). User-defined; `:build` installs first.
- **`env`** — *execution context* the dep is for (`"ci"` / `"dev"`), declared via `env :ci do ... end` inside a group. Filtered at install against the detected env (`CI` variable only — a Linux workstation is `dev`, a Mac CI runner is `ci`).
- **`host`** — *OS of the machine the dep installs on* (`:darwin` / `:linux`). Declared per-group (`group :editor, host: :darwin do ... end`) or per-declaration (`gh ..., host: :linux`). Filtered at install against the detected host OS — deps for other hosts are still resolved and locked, so the lockfile stays the single source of truth for every machine.
- **`platform`** — *what artifact variant the dep targets* (e.g. `"LinuxServer"`), for multi-arch integrations like ficsit. A resolve-time concern, not an install filter.

`env` and `host` describe *where/when a dep installs* and are first-class declaration fields; the constraint hash describes *what the dep is*.

### Built-in integrations

All built-in integrations are declared in one place — `lib/dev/deps/registry.rb` — each with a scope: `host`, `container`, or `both`. `dev deps install` on the host installs the host-scoped ones; the same command [inside the build container](#inside-the-container) installs the container-scoped ones (`bundler`, `brew` and `cask` are `both`; the rest are `host`). `registry_consistency_test.rb` fails the build if a repository/integration class or a declaration DSL verb is added without a registry entry.

| DSL method | Integration | Repository | Lockfile |
|---|---|---|---|
| `gem()` | BundlerIntegration | BundlerRepository | deps.lock |
| `cmake()` | CmakeIntegration | GitRepository / UrlRepository | deps.lock |
| `luarocks()` | LuaRocksIntegration | LuaRocksRepository | deps.lock |
| `brew()` | BrewIntegration | BrewRepository | deps.lock / build-deps.lock |
| `gh()` | GhIntegration | GhRepository | deps.lock |
| `ficsit()` | FicsitIntegration | FicsitRepository | deps.lock |
| `steam()` | SteamIntegration | SteamRepository | deps.lock |
| `xcode()` | XcodeIntegration | XcodeRepository | deps.lock |
| `pip()` | PipIntegration | PipRepository | deps.lock |

`xcode "26.1.1"` pins the Xcode toolchain (macOS only; a no-op on other hosts). dev installs the pin to `/Applications/Xcode-<ver>.app` via the [xcodes](https://github.com/XcodesOrg/xcodes) CLI — declare `brew "xcodes", host: :darwin` in `:build` so it exists first — and publishes `DEVELOPER_DIR` into the project shadowenv. Interactive runs pass any Apple ID/2FA/sudo prompt through to you; headless runs fail fast with remediation instead of hanging (normal practice: pre-install the pin interactively once during machine bring-up, e.g. a CI runner's).

`gem()` declares Ruby gems: dev generates a `Gemfile`/`Gemfile.lock` from your declarations (a top-level `gem` lands in the default group; `group(:test) { gem ... }` scopes it to a bundler group), and `dev deps install` runs `bundle install` — on the host against the host Ruby, and again [inside the build container](#inside-the-container) against the container's, each side its own bundle. `brew()` formulae ride the same lockfile pipeline as everything else: `dev deps install` installs them on the host, a container image build installs its `:build` ones from the very same `build-deps.lock` (`dev deps install --group build --integration brew`, see [dev is live infrastructure](#dev-is-live-infrastructure)), and the install inside the container the rest — all idempotently.

`python "3.12"` pins the Python toolchain: dev provisions the interpreter (Homebrew `python@3.12`) and a project-local `.venv`, and publishes it into the project shadowenv (`VIRTUAL_ENV` + `.venv/bin` on `PATH`). `pip()` declares packages installed into that venv — like `luarocks()`, you declare only the top-level packages and pip resolves the transitive tree at install time. Gate heavy, platform-specific stacks (e.g. a PyTorch-backed ML tool) with `host:` so only the machines that use them pay the download.

### Custom integrations

Projects can register their own integration types:

```ruby
require_relative "lib/my_integration"

Dev::Deps.define do
  register :my_type, MyIntegration

  group :app do
    my_type "some_dep", version: ">=1.0"
  end
end
```

Custom integrations implement `Dev::Deps::Integration` (with `install_all(pins, root:)`) and `Dev::Deps::Repository` (with `resolve(name, constraint, cache:)`).

### github: shorthand

`github: "org/repo"` expands to `repo: "https://github.com/org/repo"`. If only org is given (`github: "org"`), the dep name is appended as the repo name.

### Dependency commands

The Lifecycle builtins (see [Built-in commands](#built-in-commands)) that drive the four stages above. The dependency verbs live under one noun, `dev deps` (bare `dev deps` lists them), and are Bundler's, because that is the model every Rubyist already carries:

- **`dev deps update`** — resolve constraints from `dependencies.rb`, write lockfiles (recording the manifest digest for the staleness check), and warn, per brew formula the image build installs, when its tap ships no `x86_64_linux` bottle for the locked version — the image build's `brew install` would compile it instead of downloading it (see [Reproducible brew](#reproducible-brew)). Always available (no need to define in `dev.yml`).
- **`dev deps install [--group <g>]... [--except <g>]... [--integration <i>]... [--pinned-taps]`** — install locked deps handled on this machine (gh releases, steam apps, brew formulae, gems) into their version-keyed install dirs, filtered to the detected env and host OS. The flags narrow the set further, all repeatable: `--group` keeps only the named dependency groups, `--except` drops the named groups (and wins over `--group`), `--integration` keeps only deps of the named integrations by lock key (`brew`, `gh`, `bundler`, …). `--pinned-taps` installs brew formulae from taps checked out at the lock's commits instead of brew's API (see [Reproducible brew](#reproducible-brew)). A selection that locks no gems skips provisioning the project's pinned Ruby — nothing would consume it (this is what lets an image bootstrap on Homebrew's Ruby run `--group build --integration brew` without installing rbenv Rubies into the image). Finishes by refreshing agent skill links (see [Agent skills & org learnings](#agent-skills--org-learnings)).
- **`dev up`** — first converges the host layer (self-update + org Brewfile, see [Host tooling: the Brewfile contract](#host-tooling-the-brewfile-contract)), then auto-installs all deps from lockfiles (build group first), then brings up the project's [service dependencies](#engine--container-lifecycle) in order — the build container service, when `build.container` is declared: engine sized from the hint, image resolved, persistent container started (after the install, since the image build may mount locked build deps) — then runs the project's `up:` command from `dev.yml` if defined. On success, stamps the installed lockfile digest (see `dev deps check`). Finishes by refreshing agent skill links, like `dev deps install`. Also valid outside any project: converges the host layer only — the fresh-box bootstrap (`brew install <org>/<tap>/dev` → `dev up` → ready).
- **`dev deps check`** — report dependency-state staleness explicitly and exit non-zero when anything drifted: `dependencies.rb` vs lockfiles (digest recorded by `dev deps update`), and lockfiles vs the per-machine installed stamp (`~/.dev/state/<project>/installed-digest`, written after a fully-successful `dev up`/`dev deps install`). The same two O(1) checks run at every command start — warning on workstations, erroring in CI.
- **`dev deps path <integration> <name> <platform>`** — print the absolute path of a locked artifact (e.g. `dev deps path ficsit SML LinuxServer`, `dev deps path xcode` for the pinned DEVELOPER_DIR, or `dev deps path gh UnrealEngineMac` for a gh release's version-keyed install dir under the data root) so scripts don't reconstruct cache keys or layout conventions.

## dev plan — sync plans with GitHub issues

Global (works without a `dev.yml`; the workspace is the nearest dev.yml or git root). Sync Cursor plans with GitHub issues (ai-flow): the issue is the canonical plan, the local `.cursor/plans/gh-<n>-<slug>.plan.md` is a transient working copy carrying an `<!-- ai-flow … -->` header.

- **`new "<title>" [--blank] [--org]`** — create an issue + linked plan. Templated by default with the tech-design document (brief sections + `## Tech design` skeleton), resolved from the target repo's committed `.github/ISSUE_TEMPLATE/plan.md` when present (with a staleness warning when that mirror lags dev's bundle) else dev's bundled `share/plan-templates/tech-design.md`; `--blank` scaffolds just the H1; `--org` scaffolds a `Target repos:` line.
- **`link <n> [<file>]`** / **`link <file>`** — attach a draft to an existing issue / create one from it.
- **`pull <n> [--merge]`** — fetch, 3-way merging when both sides changed (the merge base lives at `~/.local/state/ai-flow/`).
- **`push [<file>|<n>]`** — guarded body PATCH; refuses to clobber newer remote edits. A number resolves the linked plan like `pull`.
- **`status`** — clean / ahead / behind / diverged, per linked plan.
- **`init`** — materialize/update the plan template mirror at `.github/ISSUE_TEMPLATE/plan.md` in the working tree — review with `git diff`, then commit. Only mirrors still carrying dev's marker comment are ever overwritten, so a repo customizes its template by editing the file and dropping the marker. `Dev::Plan::Templates` is the canonical owner of the template and mirror layout.

`--org` targets the org plans repo (`plans_repo:` in `~/.config/dev/config.yml`, or `DEV_PLANS_REPO`) instead of the current repo's origin. Every invocation also refreshes the user-global links for dev's shipped skills (`share/cursor-skills/*` → `~/.cursor/skills/`, so the Cursor agent knows these verbs) and the org learnings artifacts (see [Agent skills & org learnings](#agent-skills--org-learnings)). For auto-push, a participating repo adds a Cursor `afterFileEdit` hook to `.cursor/hooks.json` running `dev plan hook-after-edit` — it reads the hook payload from stdin and no-ops unless the edited file is a linked plan. What happens to a plan after it's canonical — `/ask`, `/edit`, `/split` (two-phase dry/apply), `/build` — is ai-flow's remote half: see [plan-lifecycle.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/plan-lifecycle.md) and [commands.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/commands.md).

## Agent skills & org learnings

dev distributes agent-facing skills (Cursor-style `SKILL.md` directories) over three channels, all refreshed at the same cheap, idempotent hook points — `dev up`, `dev deps install`, and `dev plan` — so there is no separate setup step:

- **dev's own skills** (`share/cursor-skills/*`) link user-globally into `~/.cursor/skills/`; `brew upgrade` refreshes them automatically because the symlinks resolve through the installed tree.
- **Gem-shipped skills.** A gem's skill is part of what installing that dependency means, so `dev up` / `dev deps install` finish by scanning the resolved (lockfile-matched) gem set for `skills/*/SKILL.md` and linking each project-scoped as `.agents/skills/gem-<gem>--<skill>` (gitignored; an agent-neutral dir, so the mechanism isn't Cursor-locked). Links for gems that leave the lock are pruned on the next install — a skill-set change rides the same staleness story as any dependency change.
- **Org learnings** (opt-in). With `knowledge_repo: <owner>/<repo>` in `~/.config/dev/config.yml` (or `DEV_KNOWLEDGE_REPO`), dev keeps a machine-local cache of the org knowledge repo under `~/.local/share/dev/knowledge`. Hooks refresh it inline with a short timeout (~2s, with a hardcoded ~30s courtesy floor between pulls — the repo is tiny, so there is no TTL knob): the pull happens *before* distribution, so a hook never renders content it just found stale, and on timeout or offline the current cache is served (the pull finishes detached). The fetch rides the user's `gh` auth. From the cache, dev links the repo's `skills/*` user-globally into `~/.cursor/skills/` and renders the index's `## Invariants (always-on)` section **once, cache-side**, then links each project's `.cursor/rules/org-invariants.mdc` at that render as a symlink — one refresh updates every project on the machine simultaneously, nothing is committed (a participating repo's only footprint is one `.gitignore` line), and drift from the canonical repo is structurally impossible. Machines without the setting simply have no org sync: dev is public and ships only the mechanism, never the content. `dev learnings sync` forces a blocking refresh of the whole read path; `dev learnings status` reports what's cached, rendered, and linked; `dev learnings invariants` prints the Tier-0 prompt block. **Runner bootstrap contract:** an agent-runner workflow (e.g. ai-flow's) runs an explicit blocking `dev learnings sync` step before starting agent sessions, so they never start on stale invariants — the dependency is stated in the workflow instead of hiding as a side effect of `dev deps install`.

### Repo learnings

Alongside the distributed channels, a repo can carry **committed learnings** — lessons distilled from review feedback, builds, and scans — as an always-on index (`.cursor/rules/learnings-index.mdc`, one `[domain/slug]` line + trigger sentence per learning) pointing at on-demand detail skills (`.cursor/skills/learnings/<slug>/SKILL.md`; architecture digests under `.cursor/skills/architecture/<topic>/`). Committed files need no distribution step: every checkout — IDE, runner, worktree — has them by construction. The index defines its own format in its preamble; this repo's copy is the reference, and `dev learnings init` seeds an unseeded repo with the same canonical (empty) index — write-once: after the scaffold is committed, humans and capture passes own the file. Capture goes through the `capture-learning` skill (shipped in `share/cursor-skills/`, so it is available in every IDE session) or ai-flow's `/learn` command on GitHub surfaces — both stage learnings as proposal PRs, and human merge is the curation gate.

### dev learnings

Global (works without a `dev.yml`); the read-path verbs for everything above:

- **`sync`** — refresh the whole learnings read path now, blocking, errors bubbling: pull the machine cache of the knowledge repo, relink skills (shipped, org, and the project's gem skills), render the invariants rule and link it into the enclosing project. Outside a project the machine-global parts run and the project-scoped ones are skipped.
- **`status`** — report the configured knowledge repo, cache location and age, and what's rendered/linked per tier.
- **`invariants`** — print the Tier-0 prompt block (the invariants section extracted from the org index) — the seam prompt-building consumers like ai-flow shell out to instead of parsing the cache themselves.
- **`init [--org]`** — scaffold the canonical empty learnings layout at the enclosing repo's root: the repo-tier index (`.cursor/rules/learnings-index.mdc` with its `alwaysApply: true` front matter, capture/curation preamble, soft cap, and org-tier trailer — no entries), or with `--org` the knowledge-repo layout (`index.md` with the fixed `## Invariants (always-on)` / `## Knowledge (on-demand)` section structure `sync` parses, plus the `skills/` corpus directory) for a new org adopting the loop. The scaffold is **write-once-committed**: an existing index is reported and left untouched (exit 0), so consumers such as ai-flow's `/learn` call `init` unconditionally before capturing into an unseeded repo. `Dev::Learnings::Layout` is the canonical owner of both tiers' paths and templates.

## Build container & caching model

For repos that declare a `build.container`, dev builds and runs commands inside a content-addressed Docker image, backed by host-side caches it owns end to end. The guiding principle throughout is **content-addressing**: an artifact's identity is a hash of its inputs, so distinct versions coexist instead of overwriting, and identical inputs are never rebuilt.

### The container engine (per-user)

*Which daemon serves a build* is a per-user provisioning decision, not a repo-shape detail: every docker invocation rides a resolved `Dev::ContainerEngine` (argv prefix + env + capabilities). There is **one supported engine per host OS**, and dev owns its lifecycle end to end — that is what lets `dev up` leave a machine where `docker build` just works, for a human and for the no-GUI agent account alike:

| Host | Engine | What `dev up` does |
|---|---|---|
| macOS | **colima** (per-user VM, `vz` + Rosetta so amd64 build images run on Apple silicon) | registers brew's `docker-buildx` with the brew `docker` CLI (`cliPluginsExtraDirs` in `~/.docker/config.json`, merged, never clobbered); brings the VM to at least the repo's `build.container.resources` hint (`cpus`, `memory_gib`; defaults 4 / 8 GiB) — see the sizing rules below |
| Linux | **dockerd in the distro** (Docker's `docker-ce` as a rootful system service; you in the `docker` group) | converges it — Docker's apt repo, `docker-ce` + `docker-buildx-plugin`, `systemctl enable --now docker`, `usermod -aG docker` — under one sudo prompt, only when something is missing (a converged box costs a few read-only probes). No VM to size; the engine is still measured against the hint |
| Windows | **dockerd inside the WSL2 distro** dev runs in | the Linux row, plus `systemd=true` in `/etc/wsl.conf` if absent, plus the VM's size: `processors` / `memory` in `%USERPROFILE%\.wslconfig` are ratcheted from the hint (see below) and you are told when a `wsl --shutdown` is due. Refuses, with instructions, while Docker Desktop's WSL integration owns `docker` in the distro |

Resolution is per invoking user: an explicit `DOCKER_HOST` in the environment wins and is left entirely alone (your engine, your problem); otherwise the `container_engine` settings record; otherwise the host OS's engine above. The only record worth writing is `docker` — the opt-out to bare docker with no env, reaching whatever daemon the CLI's own context does. That is where a Docker Desktop user lands: **unsupported but not blocked**. Two colima users on one Mac (a human and the agent account) each get `DOCKER_HOST` pointed at their **own** `~/.colima/default/docker.sock` — nothing crosses the sudo boundary. The engine's one capability flag, `local_mounts?`, names the single remote-poisoned assumption (bind-mounting local paths); every local engine answers true, and a future remote engine joins as config with its own sync strategy rather than an architecture fork.

**Engine resources: the repo's hint is a floor, and dev enforces it.** A repo's `build.container.resources` is the minimum its build was tuned for; a build on half the cores it expects is a slow, silent failure, so dev makes it loud instead. Two pieces:

- **Sizing (`dev up` and `dev runner register`).** The one VM is shared by every project the user works on, so dev sizes it as a *ratchet* — it never shrinks a VM anyone might be using. `dev runner register` runs the same step for the checked-out repo's hint before enrolling, so a host serving several repos ends up sized for the largest.

  colima (macOS):

  | VM at `dev up` | What happens |
  |---|---|
  | absent | created at the hint (defaults for fields the repo leaves out) |
  | stopped | started at exactly the hint — nobody is using a stopped VM, so this is where a VM **shrinks** back after a large project (leave a field out and the VM keeps its current value for it) |
  | running, at or above the hint | nothing |
  | running, undersized, no containers running | stopped and restarted at max(current, hint) per field |
  | running, undersized, containers running | **refused** (`EngineBusyError`) naming the containers — bring those projects down (`dev container down` there, or `dev engine down`), then `dev up` again |

  So the reclaim path after a big project is `dev engine down` (or let the busy refusal tell you to) followed by `dev up` in the smaller one.

  WSL2 (`%USERPROFILE%\.wslconfig`, `[wsl2] processors` / `memory`): the same table with one twist — dev runs *inside* the VM it is sizing, so it writes the file and the restart is yours. `wsl --shutdown` from Windows stops every distro and the runner services in them, which is exactly why dev never runs it for you. "Current" is the configured value when the file has one, else what the VM observably runs (WSL's defaults).

  | `.wslconfig` at `dev up` | What happens |
  |---|---|
  | hint above the Windows machine's hardware | **refused** (`UnsatisfiableHintError`) — lower the hint or set `engine_resources: warn` |
  | no sizes | fields WSL's default already meets are left alone (a big-enough default is not pinned); the rest are written at the hint; `[experimental] autoMemoryReclaim=gradual` is added when absent |
  | at or above the hint, and the VM runs it | nothing |
  | at or above the hint, but the VM still runs the old size | nothing rewritten — **restart pending**: `wsl --shutdown`, then `dev up` again |
  | undersized, no containers running | written at max(current, hint) per field, capped at the hardware, then **restart required** |
  | undersized, containers running | **refused** (`EngineBusyError`) naming the containers, same as colima |

  "The VM runs it" is read from the hypervisor, not the guest kernel: Hyper-V announces the VM's memory to the guest (`hv_balloon: Max. dynamic memory size: 65536 MB` in `dmesg`), and that is `memory=` to the MB, where `MemTotal` — what `docker info` reports — is only what the kernel has left after its own reservations (62.8 GiB of a 64 GB VM). dev compares exactly against the announced figure, both in the ratchet and in the final check below, so a project may ask for the whole box. `autoMemoryReclaim` is read and written under `[experimental]`, the only section WSL honors it in — under `[wsl2]` WSL warns `Unknown key` and ignores it; dev leaves such a stray line alone. Every other line in the file, its spelling and line endings included, is preserved. With WSL interop disabled dev prints one warning and leaves the VM to you. Bare Linux has no VM: the daemon already has the machine, and the check below is the whole story.

  Why WSL's `dev engine down` stops dockerd and never the VM: colima needs `colima stop` to give memory back because its VM has no ballooning; WSL hands idle memory back to Windows on its own (`autoMemoryReclaim`), and `processors` is a cap, not a reservation — so a generously sized WSL VM costs nothing at rest.

- **The engine's own lifecycle (`dev engine up | down | status`, anywhere).** `up` is the sizing step above on its own — inside a containerized project the repo's hint sizes it, elsewhere the engine's defaults apply. `status` is a pure report: the engine's kind and whether dev may stop it, running or stopped and at what size, the converge facts (colima's VM; dockerd's group / buildx / systemd state, and on WSL2 the `.wslconfig` configured-vs-observed gap that means a `wsl --shutdown` is pending), and every running container — dev's own named by the checkout they serve, the rest flagged as not dev's to manage. `down` powers the engine off (the VM on macOS; dockerd on Linux/WSL2, never the WSL VM dev lives in). The engine is the target, so what runs in it goes first: dev's build containers from any checkout are stopped without asking (`stop -t 0` keeps their writable layer, exactly what `dev container down` there does); containers dev does not manage are listed and you are asked, `--force` answering yes up front — a no leaves the engine running. An explicit `DOCKER_HOST`, and Docker Desktop behind a macOS `docker` record, are engines dev did not provision: `down` refuses and says so; `status` reports what their daemon says.

- **The check (every engine, every containerized command).** After the sizing step, and again before every image resolution (`dev <containerized command>`, `dev container up`), dev compares what the daemon reports (`docker info` cpus / memory) with the hint. A shortfall is a hard failure whose message says how to fix it for that engine kind. The escape hatch is the `engine_resources` setting — `enforce` (default) or `warn`; `DEV_ENGINE_RESOURCES` overrides — which turns the failure into a printed warning naming the layer that relaxed it, for a machine that simply cannot meet the hint. The check never resizes anything.

**Migrating a Mac off Docker Desktop.** Quit Docker Desktop (and stop it launching at login); `brew upgrade d3mlabs/d3mlabs/dev` brings `colima`, `docker` and `docker-buildx` in as formula dependencies; `dev up` in a containerized repo wires the CLI and starts the VM. Images are re-pulled/rebuilt once into the new engine's store, and a `persist: true` warm container is recreated on first use. Uninstall Desktop whenever you like — dev never touches it — but first drop `"credsStore": "desktop"` from `~/.docker/config.json` (or switch it to `osxkeychain` via `brew install docker-credential-helper`): that helper binary ships inside Docker.app and registry logins fail without it. Two colima facts worth knowing: bind mounts must live under a colima-mounted path (`~` is; `/tmp` is not), and colima's virtiofs remaps bind-mount writes to the host user just as Desktop did, so images that drop to a non-root user keep working. An agent host ends up with two colima VMs (the human's and the agent's), each sized per the rules above and each stopped by its own user's `dev engine down`.

**Migrating a WSL2 box off Docker Desktop.** In Docker Desktop > Settings > Resources > WSL integration, untick the distro (dev refuses to converge while Desktop's shim provides `docker` there, and names this step). Open a new shell, `brew upgrade d3mlabs/d3mlabs/dev`, then `dev up` in a containerized repo: one sudo prompt installs `docker-ce` in the distro and enables it; if `.wslconfig` has to grow, `dev up` says so and you `wsl --shutdown` once. Runner services on the box (`sudo systemctl restart 'actions.runner.*'`) pick up the new `docker` group membership on restart. Then `dev runner register` in each repo the host serves. Desktop itself can stay installed for other distros or go — dev never touches it.

### Content-addressed image tag

The image tag is `content-<hash>`, where the hash covers the `Dockerfile`, `.dockerignore`, both lockfiles, and any project-declared `content_globs` (file contents) / `structure_globs` (path set only). Any change to those inputs yields a new tag — and therefore a guaranteed rebuild — while an unchanged set is a guaranteed cache hit.

`ensure_image!` resolves the image in three steps, cheapest first:

1. **local** — a matching local image is honored as-is (manual builds work).
2. **pull** — otherwise pull the tag from the registry (the CI-produced image lands here).
3. **build** — only on a miss, build it locally.

**Publishing** is separate from resolution. The provisioning step opts in (set `DEV_PUBLISH_IMAGE=1`, as CI's `dev up` does) so the resolved image is pushed to the shared registry — and this runs **even on a local hit** (step 1), not only after a build. That local-hit case is the whole point: the machine that built the image (e.g. the CI runner) keeps resolving its own local copy on every run, so without publish-on-hit the registry it is meant to populate would stay empty and no other machine could ever pull. The push is registry-guarded (a remote manifest check), so it is a no-op once the tag is published. A normal local build/run leaves `DEV_PUBLISH_IMAGE` unset and never pushes.

### Prewarm

A large base dependency (e.g. a game engine) is too big to stream into a `docker build` (BuildKit's build-context transport stalls under emulation). Instead, dev builds a cheap engine-free **base** image from the `Dockerfile`, then runs the project's `prewarm:` command in a container with the dependency volume-mounted and `build_secrets` file-mounted at `/run/secrets/<id>`, and commits the result as the content tag. Secrets are bind-mounted (never `-e`), so `docker commit` can't bake them into a layer.

### The artifact store (version-keyed trees, content-addressed blobs)

Everything dev materializes under the data root goes through one seam, the **artifact store** (`Dev::Deps::ArtifactStore`; `LocalStore` is the on-disk implementation). It holds two kinds of thing:

- **Trees** — multi-GB host deps (`gh` releases, `steam` apps) install under their declared `install_dir`, **keyed by version**: `<install_dir>/<version>/…`, immutable, one dir per locked version, each stamped with a marker file. A tree key may also carry a platform (`<install_dir>/<platform>/<version>/…`) for artifacts whose contents differ per OS/arch.
- **Blobs** — content-addressed downloads (`cmake` tarballs, `ficsit` mod archives) at `<data root>/cache/<sha256>`.

Tree publication is **atomic and concurrency-safe**: the integration builds into a unique same-filesystem staging dir the store hands it, and the store publishes via a single `rename`. First writer wins — a second concurrent installer of the same version sees the published dir and discards its staging, and dev never `rm_rf`s a live directory a running job may have mounted. Switching branches (different locked versions) never reinstalls, and different-version builds can run in parallel. A build that bakes its own path into what it produces (a `ruby-build` Ruby) cannot be staged and renamed, so the store also builds such a tree **in place, marker last**: a published tree is never touched, a markerless leftover from an interrupted build is cleared and rebuilt, and nothing is found until the marker lands.

Beside the trees sit **workdirs** — platform-keyed directories mutated in place (the container Ruby's gem home): the store's layout, with no publication and no marker.

And **tool caches** — one directory per tool-mediated ecosystem's tool at `<data root>/tool-caches/<tool>`, handed to the tool as its download cache: bundler's (`BUNDLE_USER_CACHE`, with `BUNDLE_GLOBAL_GEM_CACHE`), brew's (`HOMEBREW_CACHE`), pip's (`PIP_CACHE_DIR`). dev owns the location and the tool owns the contents: the tool fetches, verifies against its own lock and installs exactly as before, but its cache now lives where the host, the container (through the data-root mount) and a cold run all see it — a pure-Ruby gem the host's `bundle install` fetched is already there when the container's runs — and where `dev cache gc --tool-caches` can reclaim it. dev never reads or writes inside a tool cache; it only names it and, when asked, drops it whole. Tools handed a cache here must tolerate concurrent writers (two checkouts installing at once) — they do, for their own users.

Integrations, `dev deps path`, the build container and `dev cache gc` all resolve paths through the store rather than reconstructing the layout, so a `dev.yml` volume like `~/.dev/engines/unreal-engine-css:/ue` is mounted from the store's tree for the locked version automatically.

### Hung-build watcher

The prewarm runs under a watcher that detects the intermittent emulated-compiler deadlock (container silent **and** ~0% CPU): it kills and retries a hang, retries a transient crash signature (e.g. a Rosetta/clang crash), and **fails fast** on a genuine compile error. Retries are capped and rely on the build tool's atomic intermediate writes, so a retry resumes incrementally.

### `dev cache gc`

dev owns the artifact store's layout, so it owns reclamation. `dev cache gc [--keep N] [--tool-caches]` applies **size-tiered, safe** retention:

- **Store trees** (multi-GB install_dir versions) get a tight default keep. Locked versions (current lockfiles) and in-use versions (mounted by a running container) are **never** evicted; orphan staging dirs from a killed install are always reclaimed.
- **docker content tags** for the project image are pruned down to the live tag (never one backing a running container).
- **Tool caches** (bundler's, brew's, pip's download caches in the store) are left alone by default and dropped **whole** with `--tool-caches`: their contents are the tool's, so dev never prunes inside one, and losing one costs a re-fetch, never correctness.

A workflow/cron only *schedules* `dev cache gc`; it never reaches into the layout itself.

### Engine & container lifecycle

Two nouns, two scopes. **`dev engine`** is the per-user daemon every project shares — global, described under [The container engine](#the-container-engine-per-user). **`dev container`** is *this checkout's* image and container; it exists only where the `dev.yml` declares a `build.container`, and never reaches another checkout.

Two intents sit on top, and they work on the project's **service dependencies** — the things that must be *running* for it to build and run, as distinct from the artifact dependencies `dependencies.rb` declares. The build container is one: an *environment* service, in that commands execute inside it. **`dev up`** installs the artifact dependencies, then brings the service dependencies up in order (the image build may mount locked build deps, so the install comes first), so the first containerized command after it finds engine, image and container ready. **`dev down`** reverses that for this checkout: the service dependencies come down in reverse order (`container down`), then the engine stops too — but only when it is dev's to stop and nothing else runs in it. Another checkout's container, or one dev does not manage, leaves the engine running and is named so you know why; exit 0 either way. `dev engine down` is the verb that reaches further. Outside a project `dev up` is the host bootstrap and starts no engine; `dev down` exists only where the project has a service dependency to bring down. `dev up` and `dev container up` are one operation with two entry points: the verb parses the command line, the intent orchestrates — which is why `dev up`'s arguments reach `dev deps install` (the intent it extends) and never a service.

| Verb | What it does |
|---|---|
| `dev container up` | Engine up and sized from this repo's hint → image resolved (local → registry → build; publishes when `DEV_PUBLISH_IMAGE=1`) → with `persist`, the service container created, or restarted warm if it exists → the container's user made the data root's owner (one `test -w` probe when it already is) → the container's dev converged to this host's version (one `dev version` probe when already current) → the container's side of the dependency install run inside (`dev deps install`, with the resolvable `run_env` entries injected). Everything a containerized command would do lazily on first use, done ahead of time. |
| `dev container down` | Stop this checkout's running containers (`stop -t 0` — PID 1 is `sleep infinity`, which ignores SIGTERM) and keep them: the writable layer is the incremental build state `persist` exists for. The engine stays up. |
| `dev container reset` | Remove this checkout's containers, the current tag's and any stale one, discarding that state. The next command creates a fresh one from the image. |
| `dev container tag` | Print the content-addressed tag the checkout resolves to. Pure — no engine, no network — so a workflow can capture it anywhere. |
| `dev container status` | The image, local and in the registry; the current tag's container and its state; stale siblings waiting for `up` to reap them. With `persist` off, the `--rm` runs in flight. Probes only. |

Every container dev starts — the persistent service and the one-shot `--rm` run alike — carries the **label contract**: `dev.managed=true`, `dev.project_root` (the checkout's real path), `dev.project`, `dev.workspace` (the checkout id the name also embeds), `dev.image`. Set operations go by label, never by name: `container down|reset` and the stale reap filter on `dev.workspace`, `dev engine down|status` read `dev.managed` / `dev.project_root` to tell dev's containers (stopped unasked, named by checkout) from yours (listed, asked about). A container without the labels is yours as far as dev is concerned.

### Inside the container

Every container dev creates also carries **`DEV_INSIDE_CONTAINER=1`** in its environment (set at creation, so every `docker exec` inherits it). It is the one marker a dev process reads to know it is inside a dev-managed container — declared by the creator, never inferred from cgroups or `/.dockerenv`, so a container somebody else started is not dev-managed unless they said so.

Three more things every dev-created container gets at creation:

- **The data root, mounted at `/var/lib/dev`** (`DEV_DATA_ROOT` inside points there), so host and container share one [artifact store](#the-artifact-store-version-keyed-trees-content-addressed-blobs). The path is fixed because what the store holds embeds absolute paths. dev creates the host directory first when it is missing, so docker never leaves a root-owned one behind. The whole root is mounted, stranded per-uid secret files under it included — the container is the same trust domain as the user who started it.
- **The host's user** — the image's user takes the uid and gid that own the mounted data root, before anything inside writes it. The container is asked, once per `dev up` / `dev container up` (persistent and cold alike), whether its user can write `/var/lib/dev`. It can — a workstation whose uid matches the image's, a Mac whose virtiofs mount is writable by any uid — and nothing happens. It cannot — a hosted runner at uid 1001 against an image `USER` at 1000 — and [`bin/container-align-user.sh`](bin/container-align-user.sh) runs as root inside: the user's `/etc/passwd` entry and its group's `/etc/group` entry take the owner's ids (`usermod` refuses while pid 1 is that user's `sleep`; `docker exec` resolves the image `USER` name at exec time, so the next exec runs as the new uid), and every file the old ids held on the container's root filesystem is re-owned — Linuxbrew's prefix included, so its ownership check keeps passing — with `-xdev` keeping the sweep off the bind mounts. A root-owned mount (the engine made the host directory) is handed to the container's user instead. Persistent containers keep the change in their writable layer; the steady state is the one probe. The consequence on both sides: every bind mount — project, data root, engine trees — is writable from inside, and what the container writes belongs to the host's user outside, with no `chown` step in any workflow. Why this and not `--user`: [ADR-0006](docs/DECISIONS.md#adr-0006--the-build-container-runs-as-the-hosts-user).
- **The host's dev, at the host's exact version** — for the persistent container, on every `dev up` / `dev container up`. The host runs `dev version` inside; when the answer differs (or nothing answers — a fresh container, an image whose bootstrap removed dev-core), it runs [`bin/container-provision-dev.sh`](bin/container-provision-dev.sh) inside: Linuxbrew's `d3mlabs/d3mlabs` tap is checked out at the commit whose `dev-core` formula shipped that version, the old keg (if any) is removed and the formula installed from there, into the writable layer. Steady state is the one probe. The install needs Linuxbrew in the image, which the [image bootstrap](#dev-is-live-infrastructure) leaves behind on purpose.

Inside, four things change:

- a containerized command **runs directly** — `shadowenv exec -- sh -c` at `/project`, with no further container to reach for. The shadowenv is the project's own: the host lisp (`510_ruby.lisp`) and a container-only one beside it (`510_ruby_container.lisp`, inert on the host — it does nothing unless the marker is set) activate the Ruby each side consumes. LLVM and Python are host toolchains; the container's come from its image;
- **the project's Ruby is a store tree**, not an rbenv one: `ruby-build` compiles it into `~/.dev/ruby/<os-arch>/<version>` under the mounted data root (in place — the prefix is baked into the binary — with the marker written last, so an interrupted build is never found and a bad one never published), its gem home is `~/.dev/gems/<os-arch>/<version>` beside it, and both outlive the container. Provisioned on first use by any containerized command, converged (version it reports, extensions it loads) by `dev deps install`. The build links Linuxbrew's openssl/readline/libyaml/zlib, and when Linuxbrew carries its own `glibc` (the image's distro is older than brew's bottles — Ubuntu 22.04's 2.35 against bottles wanting 2.38) it compiles with brew's `gcc`, the compiler those libraries were built for; the system compiler cannot link them there and ruby-build would quietly drop openssl and fiddle;
- **`dev up` is the deps install alone**: no host layer to converge (the inside dev is provisioned by the host's and cannot self-update), no credentials to prompt for (the host resolves `run_env` entries and injects them as `-e` on `docker exec` / `docker run`), no service to bring up (you are in it);
- **`dev deps install` installs the container's side and defaults to `--except build`**. Dependencies install where they are consumed: the registry's scope axis says which side each type installs on — `bundler` on both (each side's Ruby gets its own bundle), `brew` and `cask` on both, everything else (`cmake`/`url`, `gh`, `steam`, `ficsit`, `xcode`, `pip`, `luarocks`) on the host, whose artifacts the container reads through the shared store. The build group is excluded by default because the image bootstrap already installed it, and a second install would fight the image's read-only layers; an explicit `--except` replaces the default rather than adding to it. The host-side hygiene hooks (gem skill links, learnings sync) do not run inside: the links land in the mounted project tree and must name the host's paths.

The host dev owns the container's lifecycle; the dev inside owns what runs there. The marker is what keeps the two from stepping on each other.

What survives what — the warmth table:

| After… | Image | Container (writable layer) | Engine |
|---|---|---|---|
| `dev down` | kept | kept, stopped | stopped if idle and dev's, else running |
| `dev container down` | kept | kept, stopped | running |
| `dev container reset` | kept | removed | running |
| `dev engine down` | kept | kept, stopped (every checkout's) | stopped |
| a Dockerfile / lockfile change | new tag built on next use | old one reaped on next use | running |
| `docker image rm` / `dev cache gc` | re-pulled or rebuilt on next use | kept while the tag is live | running |
| `dev up --no-cache` | kept (pulled or built as usual) | kept, untouched — a one-shot sibling ran and is gone | running |

### Hosted jobs: `container: image:`

A GitHub-hosted job that runs *inside* a dev-built image (`container: image: <tag>`) has no orchestrating host: nothing created the container, so nothing set the marker, matched dev's version, or mounted a data root. The workflow is the creator, and declares the same three things a host would — through the composite action this repo ships, `d3mlabs/dev/.github/actions/hosted-up@main`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: ${{ needs.provide-image.outputs.image }}   # a prior job's `dev container up` + `dev container tag`
    steps:
      - uses: actions/checkout@v4
      - uses: d3mlabs/dev/.github/actions/hosted-up@main   # the job's `dev up`: install dev, declare the container, restore the store, run it
      - run: dev build                                     # then the project's commands, as on any host after `dev up`
```

The action puts Linuxbrew back on the job's PATH (Actions overrides a container's), installs **dev at the latest release** from the tap (there is no host version to match, so a hosted job takes a fresh workstation's shape), declares **`DEV_INSIDE_CONTAINER=1`** and the data root, restores the **artifact store from the Actions cache** (`actions/cache` on the data root, keyed `dev-store-<os>-<arch>-<hash of deps.lock + build-deps.lock>` with a prefix fallback — the store is version-keyed and content-addressed, so a stale restore is still correct and `dev up` installs the difference), runs **`dev up`** (inside: the container-side install, `--except build`), and saves the store back at the job's end. `data-root` and `up-args` are inputs. The image carries no dev ([dev is live infrastructure](#dev-is-live-infrastructure)): the Linuxbrew and tap the bootstrap leaves behind are what the install uses.

A self-hosted job has a host and needs none of this: its runner's dev runs `dev up`, which provisions the persistent container as [above](#inside-the-container).

### The cold run: `dev up --no-cache`

A warm machine hides a broken cold path: the engine already in the store, the gems already bundled, the container already provisioned. `dev up --no-cache` is the project half of `dev up` run **from nothing**, as a topology rather than a cache flush — the warm store and the persistent container are never touched, so it is safe to run on a busy box:

1. a **throwaway data root** is created beside the warm one (`<data root>-cold-<id>`) and made the process's data root for the run (`DEV_DATA_ROOT`), so every install, the tools' download caches ([tool caches](#the-artifact-store-version-keyed-trees-content-addressed-blobs) — bundler, brew and pip fetch from nothing too) and the container's data-root mount land in it;
2. the host-side `dev deps install` runs into it;
3. each service does its **cold bring-up** — for the build container: the image resolved as usual (pulled or built; the image is not what a cold run is about), then a **one-shot container** (`--rm`, a sibling of the persistent one's name, same mounts and labels) over the throwaway root, the host's dev installed inside, the container-side install run, the container removed;
4. the throwaway root is removed.

Nothing is kept: the run is a pass/fail on "can this project provision on a fresh machine today". The host layer is not converged (`dev up` does that), and the flag has no meaning inside a container (reported, then the plain install runs). It is made for a schedule — a weekly job on a self-hosted runner — at the cost of downloading everything each time, which is the point.

## Releasing a new version

Releases are distributed via the Homebrew tap at [d3mlabs/homebrew-d3mlabs](https://github.com/d3mlabs/homebrew-d3mlabs).

The release script handles everything — version bump, commit, tag, push, GitHub release, sha256, and Homebrew formula update:

```bash
./bin/release.rb                     # auto-increment patch (0.2.24 → 0.2.25)
./bin/release.rb 0.3.0               # explicit version
./bin/release.rb "Fixed the widget"  # auto-increment with custom notes
./bin/release.rb 0.3.0 "Big update"  # explicit version + notes
```

It expects the tap cloned beside this repo (`../homebrew-d3mlabs`) and checks it first — clean, on `main`, fast-forwarded to origin — before bumping anything, since the formula push is the last step and the one a stale clone breaks. A run that failed after the tag was pushed is finished by running the script again: with `HEAD` already tagged `v<VERSION>` and the formula not yet at it, it resumes at the push (idempotent), creates the GitHub release only if missing, and updates the formula — it does not bump a second version.

Verify (on any machine with the tap):

```bash
brew update
brew upgrade d3mlabs/d3mlabs/dev
dev --help
```
