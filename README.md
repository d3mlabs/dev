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
# Then e.g. rbenv install 2.7.6  (version comes from the repo’s dependencies)
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
```

- `name`: Display name for the repo (used in help output).
- `commands`: Map of command names to specs.
  - Each command has:
    - `desc`: Short description (shown in `dev` / `dev --help`).
    - `run`: Shell command to execute (from the repo root). Any extra args passed to `dev <cmd> [args...]` are forwarded to this command.

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
