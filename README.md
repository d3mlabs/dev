# dev
[![codecov](https://codecov.io/gh/d3mlabs/dev/branch/main/graph/badge.svg)](https://codecov.io/gh/d3mlabs/dev)

Global CLI tool for d3mlabs projects. Discovers `dev.yml` in your git repos and executes declared commands like `dev up`, `dev build`, `dev test`, etc.

## Installation

Install via Homebrew. Orgs install their deployment formula (tool + org configuration in one command); individuals without an org install the generic `dev-core` and write their own config — see [Org configuration & deployment](#org-configuration--deployment):

```bash
brew install d3mlabs/d3mlabs/dev        # d3mlabs (or your org's <org>/<tap>/dev)
brew install d3mlabs/d3mlabs/dev-core   # org-blank tool only
```

### System dependencies

`dev` shells out to a few external tools during `dev up` / dependency installs.
A fresh machine is often missing some, and each surfaces as a mid-run failure,
so install them up front:

```bash
# macOS and Linux (Homebrew):
brew install gh zstd            # gh: gated GitHub release downloads; zstd: engine .tar.zst extraction

# Linux runners only (git/curl preinstalled on macOS; lib32gcc-s1 = 32-bit support for SteamCMD):
sudo apt-get update && sudo apt-get install -y git curl sqlite3 lib32gcc-s1

# gh must be authenticated — dev pulls gated assets (e.g. the custom Unreal Engine) with no explicit token:
gh auth login
```

Docker is also required for repos whose builds run in containers (e.g. `dev up`
building a prewarmed image): Docker Desktop on macOS / Windows+WSL2, or Docker
Engine on Linux.

**Ruby:** We use **rbenv** as the standard Ruby version manager. If you run `dev up` in a repo that needs Ruby, have rbenv installed first:

```bash
brew install rbenv ruby-build
# Then e.g. rbenv install 2.7.6  (version comes from the repo's dependencies)
```

After installing, add the shadowenv hook to your shell so project Rubies activate when you `cd` into a repo:

```bash
# Add to ~/.zshrc (or ~/.bash_profile / config.fish)
eval "$(shadowenv init zsh)"
```

dev also ensures this hook (and the `dev cd` hook below) automatically and idempotently when you run `dev up` in a project, so a manual edit is only needed if you want it before your first `dev up`.

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

Keep the file a bare version string. rbenv only reads the first word, but other consumers (setup-ruby, Bundler, editors) parse the file strictly, so comments would break them. There is no drift risk in the other direction either: `dev up` rewrites the file from the declared version every run, so a hand edit never survives — to change the Ruby, edit `dependencies.rb`, run `dev update-deps`, then `dev up`.

### Supported shells

All dev shell RC hooks — shadowenv activation and the `dev cd` wrapper + completers — are installed for **zsh, bash, and fish** (`~/.zshrc`, `~/.bash_profile` or `~/.bashrc`, `~/.config/fish/config.fish`). Other shells are unsupported for hooks: `dev` project commands still run, but there is no env activation and no `dev cd`.

**Formula maintainers:** The Homebrew formula for `d3mlabs/dev` should include `depends_on "shadowenv"` so developers get shadowenv when they install dev. Formulas must never edit shell RCs — dev installs its hooks itself on its own command paths (`dev up`, `dev cd`).

## Adoption model

dev's feature set is three independent opt-ins; a repo takes whichever rungs it needs, in any combination:

1. **Command running** — add a `dev.yml` with a `commands:` map. That alone gets you `dev up` / `dev test` / etc. with the standard UI, from anywhere in the repo. dev does not touch your toolchain or dependencies; your scripts keep doing whatever they did before.
2. **Toolchain provisioning** — add a `dependencies.rb` with just a `ruby` directive (see [Ruby version resolution](#ruby-version-resolution)). dev provisions that exact Ruby (rbenv + shadowenv) and every `dev <cmd>` runs under it. This does *not* hand your Gemfile to dev — a hand-written Gemfile stays yours, managed by plain bundler.
3. **Dependency management** — declare gems, brew formulae, engine artifacts, etc. in `dependencies.rb`. `dev update-deps` locks them and `dev up` installs them; for `gem()` declarations dev generates and owns the `Gemfile`.

A gem repo typically stops at rungs 1–2 (commands + a pinned Ruby, hand-written gemspec/Gemfile); an app repo usually takes all three.

## Org configuration & deployment

dev's source hardcodes no org content — every org-specific fact enters through **settings**, resolved per key with gitconfig-style layering (`Dev::Settings`):

1. **ENV var** — `DEV_PLANS_REPO`, `DEV_KNOWLEDGE_REPO`, `DEV_DEPLOYMENT_FORMULA`. Highest precedence.
2. **User file** — `~/.config/dev/config.yml` (or `$XDG_CONFIG_HOME/dev/config.yml`).
3. **System file** — `$(brew --prefix)/etc/dev/config.yml`, shipped by an org's deployment formula.

Missing files are empty layers; a key set in the user file wins over the system file. The keys:

```yaml
plans_repo: d3mlabs/plans              # org-wide plans repo (dev plan --org)
knowledge_repo: d3mlabs/knowledge      # org learnings sync source
deployment_formula: d3mlabs/d3mlabs/dev  # the formula `dev up` self-updates (the deployment names itself)
```

Leaving a nilable key unset turns its feature off (`plans_repo` is only required by `dev plan --org`). Manage the user file with `dev config` (`list` / `get <key>` / `set <key> <value>`) instead of hand-editing YAML. The tool ships as two kinds of formula (the Debian core-package/config-package split, applied to a tap):

- **`d3mlabs/d3mlabs/dev-core`** — the generic tool, org-blank: the build payload plus the tools dev itself shells out to (git, gh, ruby, rbenv, ruby-build, shadowenv). It ships no org content.
- **A deployment formula named `dev` in each org's tap** — `depends_on "d3mlabs/d3mlabs/dev-core"` plus the org's payload installed into the prefix's `etc/dev/` (pkgetc — brew preserves locally-modified etc files across upgrades): a `config.yml` with the org's keys (including `deployment_formula`, its own name — that's how `dev up` knows what to upgrade) and an optional `Brewfile` with the org's host tooling (see [Host tooling: the Brewfile contract](#host-tooling-the-brewfile-contract)). Formula names only need to be unique within a tap, so every org's install is the same shape: `brew install d3mlabs/d3mlabs/dev` is the reference deployment, and an adopting org publishes `acme/tap/dev` with identical structure and its own payload.

Three consumption stories:

- **Org deployment (recommended):** `brew install <org>/<tap>/dev` — one command installs tool + identity, and the org evolves its config and tooling list by shipping a new deployment formula revision; every machine picks it up on its next `dev up`.
- **Individual / handrolled:** `brew install d3mlabs/d3mlabs/dev-core`, then `dev config set <key> <value>` for the keys you need — no org involvement, useful for personal machines or orgs without a tap. No Brewfile means the host tooling step self-skips.
- **CI / fleet:** set the ENV vars in the pipeline or MDM profile — no files needed, and they override both file layers.

Installs predating the split (when `dev` was a monolithic tool+config formula) migrate with a hard cut: `brew uninstall dev && brew install d3mlabs/d3mlabs/dev`.

## Usage

From anywhere under a git repo that has a `dev.yml` at its root:

```bash
dev up       # Run the 'up' command (e.g. setup)
dev build    # Run the 'build' command
dev test     # Run the 'test' command
dev          # List all available commands
```

The tool walks up from your current directory until it finds a git repo root (directory containing `.git`), then looks for `dev.yml` there. If found, it parses the commands and executes the `run` string for your chosen subcommand.

A few builtins are global and work from **any** directory, no `dev.yml` needed: `dev cd` (host-global navigation), `dev clone` (host-global checkout creation), `dev config` (host-global settings), `dev cred` (host-global credentials), and `dev plan` (workspace-global plan sync). Project commands (`dev up` and anything declared in `dev.yml`) still require a nearby `dev.yml`.

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
dev clone myrepo           # org defaults to d3mlabs → ~/src/github.com/d3mlabs/myrepo
dev clone acme/widget      # explicit org
```

It is clone-only by design — no automatic `dev up`. Provisioning stays a deliberate second step, because a first `dev up` is where credential prompts happen and you should see them coming. The fresh-machine story is three commands: `brew install d3mlabs/d3mlabs/dev` → `dev clone <repo>` → `dev up`.

If the canonical destination already exists, `dev clone` errors and points you at `dev cd`. Without the shell wrapper active (e.g. the very first dev command on a fresh machine), the clone still happens; dev installs the hook for next time and prints the destination instead of jumping there.

### Shell hook install

`dev cd` and the landing half of `dev clone` need a small shell wrapper — a Ruby child process cannot change your shell's directory. dev installs the wrapper function and Tab completers into your shell RC automatically and idempotently: on `dev up` in any project, and on `dev cd` / a hook-less `dev clone` themselves (so a first use self-heals the hook; open a new shell after the install hint). The snippet is marker-guarded (`# dev cd + clone (added by dev)`) next to the shadowenv one, and re-runs never duplicate it; when the snippet itself evolves, the marker changes with it and the next ensure appends the updated wrapper, whose later definition wins.

Tab completion is registered per shell: zsh gets a navigable menu-select list scoped to the `dev` command only (your other commands' completion is untouched; registration is skipped quietly if your zshrc never runs `compinit`), bash fills `COMPREPLY` directly, and fish registers a standard pager completion (fish applies its own filtering, so fuzzy tokens may only complete literally there). Completion fills the argument only — it never runs the `cd` for you — and inserts `org/repo` (or deeper) forms when a short name would collide.

Because the wrapper runs `builtin cd` in your interactive shell, shadowenv activation after `dev cd` behaves exactly like a manual `cd`: if the shadowenv hook is in your RC (see above), the project env loads; if it's missing, `dev cd` still changes directory but no env activates — same as plain `cd`.

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
```

- `name`: Display name for the repo (used in help output).
- `commands`: Map of command names to specs.
  - Each command has:
    - `desc`: Short description (shown in `dev` / `dev --help`).
    - `run`: Shell command to execute (from the repo root). Any extra args passed to `dev <cmd> [args...]` are forwarded to this command.
    - `repl`: *(optional, default `false`)* When `true`, the command execs directly without a status footer. Use this for long-running interactive sessions like consoles and REPLs where a trailing `✓ Done` doesn't make sense.
    - `container`: *(optional, default `true` when `build.container` is configured)* When `false`, the command runs on the host (via `shadowenv exec`) instead of inside the build container. Use for host-side commands like provisioning (`up`) or deploying.
    - `hidden`: *(optional, default `false`)* When `true`, the command is still callable (`dev <cmd>`) but omitted from `dev` / `dev --help` output. Use for internal plumbing — e.g. a `build` primitive that an intent command (`test`, `release`) calls but that developers shouldn't invoke directly.

## Examples

```bash
# From repo root or any subdirectory
cd /path/to/myproject
dev up          # Runs ./bin/setup.rb
dev up -v       # Runs ./bin/setup.rb -v
dev test        # Runs ./bin/test.sh
dev build       # Runs ./bin/build.sh

# Help
dev             # Lists all commands
dev --help      # Same
```

## Error handling

- If no git repo is found above your current directory: `dev: no git repo (with dev.yml) found above <path>`
- If a git repo is found but has no `dev.yml`: `dev: found git repo at <path> but no dev.yml there`
- If you run an unknown command: `dev: unknown command: <name>` (and shows available commands)

## Dependency management

Dev includes a built-in dependency management system for reproducible builds across ecosystems.

### Lifecycle

Dependencies flow through four stages:

1. **Declare** — list what you need in `dependencies.rb` using the Ruby DSL
2. **Resolve & lock** — `dev update-deps` resolves constraints to exact versions and writes lockfiles
3. **Install** — `dev up` installs pinned dependencies from lockfiles (build group first)
4. **Use** — `dev <command>` provisions the project's toolchain environment and runs your command

Lockfiles are the source of truth for stages 3 and 4. After changing `dependencies.rb`, run `dev update-deps` to re-resolve before building.

### Lockfiles

Two YAML lockfiles, same format, two purposes:

- **`deps.lock`** — pins every runtime dependency (app + test groups) to exact version + SHA256 integrity hash.
- **`build-deps.lock`** — pins every build dependency (build group). Separate file for CI cache convenience — `hashFiles('build-deps.lock')` as Docker image cache key means runtime dep changes don't invalidate build tooling.

Both files are generated by `dev update-deps` and committed to git. Never edit them by hand.

### Host tooling: the Brewfile contract

Alongside per-project dependencies, an org converges **host tooling** — the org-invariant tools every developer machine needs regardless of which projects it serves (an editor-class agent CLI, say). The principle is **brew converges brew**: dev never re-implements host tooling convergence, it only *triggers* brew's — the same way it triggers bundler for gems.

- **The list lives in the deployment formula's `Brewfile`**, installed into `$(brew --prefix)/etc/dev/` beside `config.yml`. Convention, not configuration: file present means `dev up` runs `brew bundle install` against it; absent (tapless individual, CI) means the step self-skips. No settings key, no fetch, no cache — the file is local, delivered by packaging.
- **Disjoint sets:** `dev-core`'s `depends_on` answers "what does the tool need" (git, gh, ruby, rbenv, ruby-build, shadowenv); the Brewfile answers "what does the org want beyond that". No entry ever appears in both; if dev drops a dep the org still wants, that fact migrates to the Brewfile. Tools that belong to one piece of software stay in that repo's own `dependencies.rb`.
- **Private taps:** Brewfiles natively support `tap` entries, including private taps over authenticated git — sensitive tooling goes in a private tap the Brewfile references. `gh auth login` must precede `dev up` in that case (the failure mode is brew's own clear git-auth error).
- **Trust model:** a Brewfile is brew-evaluated Ruby DSL, so converging it executes org-authored code — the same trust already granted by installing the org's deployment formula. dev adds no new trust surface: the file lives in the brew prefix at a fixed path, never a user-supplied one, and brew's tap-trust gate covers formulas from untrusted taps.

On every `dev up`, before project provisioning, `Dev::Host::Converge` runs the host layer: a **throttled `brew update`** (daily stamp under `$XDG_DATA_HOME/dev/host/`), a **scoped `brew upgrade` of the `deployment_formula`** the deployment named in its own `config.yml` (falling back to `dev-core` for tapless individuals; skipped entirely for source checkouts — never a blanket `brew upgrade` of unrelated packages), then **`brew bundle install`** against the Brewfile when one exists (not throttled — an upgrade may land a new Brewfile the same run must converge). The whole layer is warn-only: offline machines and failed upgrades never block project provisioning. Upgrading is symmetric: the org edits one line in its tap's Brewfile (or ships a config change via formula revision) and every machine converges on its next `dev up` — no brew vocabulary required, though a direct `brew upgrade` keeps working for users who prefer it.

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

All built-in integrations are declared in one place — `lib/dev/deps/registry.rb` — and `dev install-deps` installs every host-scoped one. `registry_consistency_test.rb` fails the build if a repository/integration class or a declaration DSL verb is added without a registry entry.

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

`gem()` declares Ruby gems: dev generates a `Gemfile`/`Gemfile.lock` from your declarations (a top-level `gem` lands in the default group; `group(:test) { gem ... }` scopes it to a bundler group), and `dev install-deps` runs `bundle install`. `brew()` dual-writes — the container build path keeps reading the group structure while `dev install-deps` also installs the formulae on the host (idempotently).

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

### Built-in commands

- **`dev update-deps`** — resolve constraints from `dependencies.rb`, write lockfiles (recording the manifest digest for the staleness check). Always available (no need to define in `dev.yml`).
- **`dev install-deps`** — install locked deps handled on the host (gh releases, steam apps) into their version-keyed install dirs, filtered to the detected env and host OS. Finishes by refreshing agent skill links (see [Agent skills & org learnings](#agent-skills--org-learnings)).
- **`dev up`** — first converges the host layer (throttled self-update + org Brewfile, see [Host tooling: the Brewfile contract](#host-tooling-the-brewfile-contract)), then auto-installs all deps from lockfiles (build group first), then runs the project's `up:` command from `dev.yml` if defined. On success, stamps the installed lockfile digest (see `dev check`). Finishes by refreshing agent skill links, like `install-deps`. Also valid outside any project: converges the host layer only — the fresh-box bootstrap (`brew install <org>/<tap>/dev` → `dev up` → ready).
- **`dev check`** — report dependency-state staleness explicitly: `dependencies.rb` vs lockfiles (digest recorded by `update-deps`), and lockfiles vs the per-machine installed stamp (`~/.dev/state/<project>/installed-digest`, written after a fully-successful `up`/`install-deps`). The same two O(1) checks run at every command start — warning on workstations, erroring in CI.
- **`dev deps path <integration> <name> <platform>`** — print the absolute path of a locked artifact (e.g. `dev deps path ficsit SML LinuxServer`, or `dev deps path xcode` for the pinned DEVELOPER_DIR) so scripts don't reconstruct cache keys or layout conventions.
- **`dev config list | get <key> | set <key> <value>`** — manage dev's settings (see [Org configuration & deployment](#org-configuration--deployment)). `list` shows every known key with its resolved value and source layer (`env` / `user` / `system` / unset) — the settings debugging tool; `get` prints the resolved value (exit 1 when unset); `set` writes the user file (`~/.config/dev/config.yml`), creating it if missing. Known keys only. Global: works without a `dev.yml`.
- **`dev cred get <namespace> <key>`** — resolve a credential through the provider chain (ENV → keychain → file → prompt) and print it. A non-interactive miss errors with `gh secret set` guidance. Mirrors `dev deps path` for shell consumers (e.g. a staging sync). Global: works without a `dev.yml`.
- **`dev cd <repo>`** — jump to a checkout under `$DEV_CD_ROOT` (default `~/src`) by fuzzy name, with Tab completion (see [dev cd](#dev-cd--jump-between-checkouts)). Global: works without a `dev.yml`.
- **`dev clone [<org>/]<repo>`** — clone a GitHub repo via your `gh` auth into the canonical `$DEV_CD_ROOT/github.com/<org>/<repo>` path (org defaults to `d3mlabs`) and land there (see [dev clone](#dev-clone--clone-into-the-canonical-layout)). Clone-only — run `dev up` yourself. Global: works without a `dev.yml`.
- **`dev cache gc [--keep N]`** — reclaim host caches dev owns (see below).
- **`dev reset-container`** — remove the persistent build container (clears its incremental cache); registered only when `build.container.persist` is set.
- **`dev plan …`** — global (works without a `dev.yml`; the workspace is the nearest dev.yml or git root). Sync Cursor plans with GitHub issues (ai-flow): the issue is the canonical plan, the local `.cursor/plans/gh-<n>-<slug>.plan.md` is a transient working copy carrying an `<!-- ai-flow … -->` header. Subcommands: `new "<title>" [--blank] [--org]` (create issue + linked plan — templated by default with the tech-design document (brief sections + `## Tech design` skeleton), resolved from the target repo's committed `.github/ISSUE_TEMPLATE/plan.md` when present (with a staleness warning when that mirror lags dev's bundle) else dev's bundled `share/plan-templates/tech-design.md`; `--blank` scaffolds just the H1; `--org` scaffolds a `Target repos:` line), `link <n> [<file>]` / `link <file>` (attach a draft to an existing issue / create one from it), `pull <n> [--merge]` (fetch, 3-way merging when both sides changed — the merge base lives at `~/.local/state/ai-flow/`), `push [<file>|<n>]` (guarded body PATCH — refuses to clobber newer remote edits; a number resolves the linked plan like `pull`), `status` (clean / ahead / behind / diverged, per linked plan), and `init` (materialize/update the plan template mirror at `.github/ISSUE_TEMPLATE/plan.md` in the working tree — review with `git diff`, then commit; only mirrors still carrying dev's marker comment are ever overwritten, so a repo customizes its template by editing the file and dropping the marker). `Dev::Plan::Templates` is the canonical owner of the template and mirror layout. `--org` targets the org plans repo (`plans_repo:` in `~/.config/dev/config.yml`, or `DEV_PLANS_REPO`) instead of the current repo's origin. Every invocation also refreshes the user-global links for dev's shipped skills (`share/cursor-skills/*` → `~/.cursor/skills/`, so the Cursor agent knows these verbs) and the org learnings artifacts (see [Agent skills & org learnings](#agent-skills--org-learnings)). For auto-push, a participating repo adds a Cursor `afterFileEdit` hook to `.cursor/hooks.json` running `dev plan hook-after-edit` — it reads the hook payload from stdin and no-ops unless the edited file is a linked plan. What happens to a plan after it's canonical — `/ask`, `/edit`, `/split` (two-phase dry/apply), `/build` — is ai-flow's remote half: see [plan-lifecycle.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/plan-lifecycle.md) and [commands.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/commands.md).
- **`dev learnings sync|status|invariants|init`** — global (works without a `dev.yml`). `sync` refreshes the whole learnings read path now, blocking, errors bubbling: pull the machine cache of the knowledge repo, relink skills (shipped, org, and the project's gem skills), render the invariants rule and link it into the enclosing project. Outside a project the machine-global parts run and the project-scoped ones are skipped. `status` reports the configured knowledge repo, cache location and age, and what's rendered/linked per tier. `invariants` prints the Tier-0 prompt block (the invariants section extracted from the org index) — the seam prompt-building consumers like ai-flow shell out to instead of parsing the cache themselves. `init` scaffolds the canonical empty learnings layout at the enclosing repo's root: the repo-tier index (`.cursor/rules/learnings-index.mdc` with its `alwaysApply: true` front matter, capture/curation preamble, soft cap, and org-tier trailer — no entries), or with `--org` the knowledge-repo layout (`index.md` with the fixed `## Invariants (always-on)` / `## Knowledge (on-demand)` section structure `dev learnings sync` parses, plus the `skills/` corpus directory) for a new org adopting the loop. The scaffold is **write-once-committed**: an existing index is reported and left untouched (exit 0), so consumers such as ai-flow's `/learn` call `init` unconditionally before capturing into an unseeded repo. `Dev::Learnings::Layout` is the canonical owner of both tiers' paths and templates. See [Agent skills & org learnings](#agent-skills--org-learnings).

## Agent skills & org learnings

dev distributes agent-facing skills (Cursor-style `SKILL.md` directories) over three channels, all refreshed at the same cheap, idempotent hook points — `dev up`, `dev install-deps`, and `dev plan` — so there is no separate setup step:

- **dev's own skills** (`share/cursor-skills/*`) link user-globally into `~/.cursor/skills/`; `brew upgrade` refreshes them automatically because the symlinks resolve through the installed tree.
- **Gem-shipped skills.** A gem's skill is part of what installing that dependency means, so `dev up` / `dev install-deps` finish by scanning the resolved (lockfile-matched) gem set for `skills/*/SKILL.md` and linking each project-scoped as `.agents/skills/gem-<gem>--<skill>` (gitignored; an agent-neutral dir, so the mechanism isn't Cursor-locked). Links for gems that leave the lock are pruned on the next install — a skill-set change rides the same staleness story as any dependency change.
- **Org learnings** (opt-in). With `knowledge_repo: <owner>/<repo>` in `~/.config/dev/config.yml` (or `DEV_KNOWLEDGE_REPO`), dev keeps a machine-local cache of the org knowledge repo under `~/.local/share/dev/knowledge`. Hooks refresh it inline with a short timeout (~2s, with a hardcoded ~30s courtesy floor between pulls — the repo is tiny, so there is no TTL knob): the pull happens *before* distribution, so a hook never renders content it just found stale, and on timeout or offline the current cache is served (the pull finishes detached). The fetch rides the user's `gh` auth. From the cache, dev links the repo's `skills/*` user-globally into `~/.cursor/skills/` and renders the index's `## Invariants (always-on)` section **once, cache-side**, then links each project's `.cursor/rules/org-invariants.mdc` at that render as a symlink — one refresh updates every project on the machine simultaneously, nothing is committed (a participating repo's only footprint is one `.gitignore` line), and drift from the canonical repo is structurally impossible. Machines without the setting simply have no org sync: dev is public and ships only the mechanism, never the content. `dev learnings sync` forces a blocking refresh of the whole read path; `dev learnings status` reports what's cached, rendered, and linked; `dev learnings invariants` prints the Tier-0 prompt block. **Runner bootstrap contract:** an agent-runner workflow (e.g. ai-flow's) runs an explicit blocking `dev learnings sync` step before starting agent sessions, so they never start on stale invariants — the dependency is stated in the workflow instead of hiding as a side effect of `install-deps`.

### Repo learnings

Alongside the distributed channels, a repo can carry **committed learnings** — lessons distilled from review feedback, builds, and scans — as an always-on index (`.cursor/rules/learnings-index.mdc`, one `[domain/slug]` line + trigger sentence per learning) pointing at on-demand detail skills (`.cursor/skills/learnings/<slug>/SKILL.md`; architecture digests under `.cursor/skills/architecture/<topic>/`). Committed files need no distribution step: every checkout — IDE, runner, worktree — has them by construction. The index defines its own format in its preamble; this repo's copy is the reference, and `dev learnings init` seeds an unseeded repo with the same canonical (empty) index — write-once: after the scaffold is committed, humans and capture passes own the file. Capture goes through the `capture-learning` skill (shipped in `share/cursor-skills/`, so it is available in every IDE session) or ai-flow's `/learn` command on GitHub surfaces — both stage learnings as proposal PRs, and human merge is the curation gate.

## Build container & caching model

For repos that declare a `build.container`, dev builds and runs commands inside a content-addressed Docker image, backed by host-side caches it owns end to end. The guiding principle throughout is **content-addressing**: an artifact's identity is a hash of its inputs, so distinct versions coexist instead of overwriting, and identical inputs are never rebuilt.

### Content-addressed image tag

The image tag is `content-<hash>`, where the hash covers the `Dockerfile`, `.dockerignore`, both lockfiles, and any project-declared `content_globs` (file contents) / `structure_globs` (path set only). Any change to those inputs yields a new tag — and therefore a guaranteed rebuild — while an unchanged set is a guaranteed cache hit.

`ensure_image!` resolves the image in three steps, cheapest first:

1. **local** — a matching local image is honored as-is (manual builds work).
2. **pull** — otherwise pull the tag from the registry (the CI-produced image lands here).
3. **build** — only on a miss, build it locally.

**Publishing** is separate from resolution. The provisioning step opts in (set `DEV_PUBLISH_IMAGE=1`, as CI's `dev up` does) so the resolved image is pushed to the shared registry — and this runs **even on a local hit** (step 1), not only after a build. That local-hit case is the whole point: the machine that built the image (e.g. the CI runner) keeps resolving its own local copy on every run, so without publish-on-hit the registry it is meant to populate would stay empty and no other machine could ever pull. The push is registry-guarded (a remote manifest check), so it is a no-op once the tag is published. A normal local build/run leaves `DEV_PUBLISH_IMAGE` unset and never pushes.

### Prewarm

A large base dependency (e.g. a game engine) is too big to stream into a `docker build` (BuildKit's build-context transport stalls under emulation). Instead, dev builds a cheap engine-free **base** image from the `Dockerfile`, then runs the project's `prewarm:` command in a container with the dependency volume-mounted and `build_secrets` file-mounted at `/run/secrets/<id>`, and commits the result as the content tag. Secrets are bind-mounted (never `-e`), so `docker commit` can't bake them into a layer.

### install_dir content-addressing (version-keyed)

Multi-GB host deps (`gh` releases, `steam` apps) bypass the download cache and install under their declared `install_dir`, **keyed by version**:

```
<install_dir>/<version>/…        # immutable; one dir per locked version
```

Installs are **atomic and concurrency-safe**: dev builds into a unique same-filesystem staging dir, stamps a marker, then publishes via a single `rename`. First writer wins — a second concurrent installer of the same version sees the published dir and discards its staging, and dev never `rm_rf`s a live directory a running job may have mounted. Switching branches (different locked versions) never reinstalls, and different-version builds can run in parallel.

dev resolves the configured volume/build-context onto the right versioned subdir from the lockfile, so a `dev.yml` volume like `~/.dev/engines/unreal-engine-css:/ue` is mounted from `…/unreal-engine-css/<locked-version>` automatically.

### Hung-build watcher

The prewarm runs under a watcher that detects the intermittent emulated-compiler deadlock (container silent **and** ~0% CPU): it kills and retries a hang, retries a transient crash signature (e.g. a Rosetta/clang crash), and **fails fast** on a genuine compile error. Retries are capped and rely on the build tool's atomic intermediate writes, so a retry resumes incrementally.

### `dev cache gc`

dev owns the cache layout, so it owns reclamation. `dev cache gc [--keep N]` applies **size-tiered, safe** retention:

- **install_dir versions** (multi-GB) get a tight default keep. Locked versions (current lockfiles) and in-use versions (mounted by a running container) are **never** evicted; orphan staging dirs from a killed install are always reclaimed.
- **docker content tags** for the project image are pruned down to the live tag (never one backing a running container).

A workflow/cron only *schedules* `dev cache gc`; it never reaches into the layout itself.

## Releasing a new version

Releases are distributed via the Homebrew tap at [d3mlabs/homebrew-d3mlabs](https://github.com/d3mlabs/homebrew-d3mlabs).

The release script handles everything — version bump, commit, tag, push, GitHub release, sha256, and Homebrew formula update:

```bash
./bin/release.rb                     # auto-increment patch (0.2.24 → 0.2.25)
./bin/release.rb 0.3.0               # explicit version
./bin/release.rb "Fixed the widget"  # auto-increment with custom notes
./bin/release.rb 0.3.0 "Big update"  # explicit version + notes
```

Verify (on any machine with the tap):

```bash
brew update
brew upgrade d3mlabs/d3mlabs/dev
dev --help
```
