# dev

Global CLI tool for d3mlabs projects. Discovers `dev.yml` in your git repos and executes declared commands like `dev up`, `dev build`, `dev test`, etc.

## Installation

Install via Homebrew (from the d3mlabs tap). This installs `dev` and shadowenv (for per-project Ruby env in repos that use `dev up`):

```bash
brew tap d3mlabs
brew install d3mlabs/dev
```

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

**Formula maintainers:** The Homebrew formula for `d3mlabs/dev` should include `depends_on "shadowenv"` so developers get shadowenv when they install dev.

## Usage

From anywhere under a git repo that has a `dev.yml` at its root:

```bash
dev up       # Run the 'up' command (e.g. setup)
dev build    # Run the 'build' command
dev test     # Run the 'test' command
dev          # List all available commands
```

The tool walks up from your current directory until it finds a git repo root (directory containing `.git`), then looks for `dev.yml` there. If found, it parses the commands and executes the `run` string for your chosen subcommand.

## Child script UI

Dev uses [Shopify's cli-ui](https://github.com/Shopify/cli-ui) for frames, colors, and spinners. All non-repl commands run as subprocesses with their output piped through a PTY. Child scripts can use any of three approaches to produce UI output.

Commands marked `repl: true` bypass this entirely and replace the dev process (`exec`), giving the child command direct terminal access.

### Three-tier rendering

Dev adapts its own rendering based on the environment:

- **TTY (terminal)** -- detected via `$stdout.tty?` -- full cli-ui: frames, colors, animated spinners
- **CI** -- detected via `CI` or `CLICOLOR_FORCE` env var -- frames and colors, static checkmarks (no spinner animation)
- **Pipe/file** -- neither of the above -- plain text fallback

### Approach A: Protocol markers

Child scripts output structured markers; dev parses and renders them. No cli-ui dependency needed in the child. Best for shell scripts and CI-facing commands.

```
::frame::Title       Open a cli-ui frame
::endframe::         Close the current frame
::ok::label          Green checkmark + label
::fail::label        Red X + label
::warn::message      Yellow warning message
::spin::label        Start animated spinner, drain lines until endspin
::endspin::          End spin with success (checkmark)
::endspin::fail      End spin with failure (X)
```

Example (`bin/setup.sh`):

```bash
#!/bin/sh
echo "::frame::Dependencies"
echo "::ok::ruby 4.0.1"
echo "::ok::bundler"
echo "::spin::Installing cmake"
brew install cmake >/dev/null 2>&1
echo "::endspin::"
echo "::endframe::"
```

### Approach B: CLI::UI in child scripts

Child scripts use CLI::UI directly (frames, spinners, colors). The output passes through the PTY and is written directly to the terminal, bypassing the parent's StdoutRouter. This gives the richest real-time rendering (animated spinners in the child process itself) but requires the cli-ui gem.

### Approach C: Plain text

Child scripts output plain text. It passes through unmodified. Simplest option.

### Environment comparison

**Rendering:**

| | Protocol markers | CLI::UI in child | Plain text |
|---|---|---|---|
| Dev terminal | Dev renders frames, colors, animated spinners | Child renders natively via PTY; full frames/spinners/colors | Raw text |
| CI | Dev renders frames/colors, static checkmarks; CI-safe | Child sees PTY (thinks TTY), renders spinners that CI log viewers may garble | Clean logs |
| Cursor | Same as dev terminal | Same as dev terminal | Raw text |
| Without dev | Markers appear as readable plain text | CLI::UI renders directly to terminal | Raw text |

**Ruby / environment resolution:**

| | How Ruby resolves |
|---|---|
| Dev terminal | `dev` uses Homebrew Ruby (shell trampoline in `bin/dev`). Child commands get the project's Ruby via `shadowenv exec --`. |
| CI | Docker image provides Ruby. Scripts run directly (not via `dev`). |
| Cursor sandbox | `dev <cmd>` resolves Ruby correctly. `.cursor/rules/dev.mdc` instructs the AI agent to always use `dev <cmd>`. Shell trampolines in child scripts are NOT needed -- only `d3mlabs/dev`'s own bin/ scripts need them (bootstrapping: can't use `dev` to run `dev` itself). |

**When to use each approach:**

- **Protocol markers**: Default for new scripts. Works everywhere, CI-safe, no gem dependency.
- **CLI::UI in child**: Dev-only scripts that benefit from real-time spinner animation and won't run in CI.
- **Plain text**: When structured output isn't needed.

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
    - `repl`: *(optional, default `false`)* When `true`, the command replaces the dev process (via `exec`) instead of running inside a cli-ui frame. Use this for interactive commands like consoles and REPLs that need direct terminal access.

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
