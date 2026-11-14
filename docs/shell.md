# Shell integration

`dev cd` and `dev clone` move your shell between checkouts; `dev cred`
resolves credentials for scripts. All three work without a `dev.yml`.

## Shell hooks

`dev up` installs two snippets into your shell RC, for zsh (`~/.zshrc`),
bash (`~/.bash_profile` or `~/.bashrc`) and fish
(`~/.config/fish/config.fish`):

- the shadowenv hook (`eval "$(shadowenv init <shell>)"`), which activates
  a project's environment when you `cd` into it;
- the `dev cd` / `dev clone` wrapper and Tab completers.

The install is idempotent and marker-guarded; re-running never duplicates
a snippet. `dev cd` and a hook-less `dev clone` install the wrapper too.
Open a new shell after the first install. Other shells run project
commands but get no environment activation and no `dev cd`.

## dev cd

```bash
dev cd myrepo              # unique fuzzy match → cd there
dev cd d3mlabs/myrepo      # org/repo when names collide
dev cd d3m/d               # fuzzy on each side of the slash
dev cd myr<TAB>            # complete: list matches, select or refine
dev cd <TAB>               # list every candidate
```

The search root is `$DEV_CD_ROOT`, default `~/src`, laid out as
`~/src/github.com/<org>/<repo>`. Set the variable in your RC if your
checkouts live elsewhere.

Only git repos are candidates (a `.git` directory or worktree file). The
query matches path segments from the right: `dev` matches the leaf,
`d3mlabs/dev` the org and leaf, `bitbucket.org/d3mlabs/dev` the host too.
An ambiguous query lists the candidates (up to 10, each at the shortest
unique depth) and exits non-zero.

Because the wrapper runs `builtin cd`, shadowenv activation after `dev cd`
behaves exactly as after a manual `cd`.

## dev clone

```bash
dev clone myrepo           # needs default_org; → ~/src/github.com/<default_org>/myrepo
dev clone acme/widget      # explicit org
```

Clones through your `gh` login into `$DEV_CD_ROOT/github.com/<org>/<repo>`
and lands your shell there. A bare `<repo>` needs the `default_org` setting
(`dev config set default_org d3mlabs`, or `DEV_DEFAULT_ORG`).

`dev clone` does not run `dev up`. Provisioning is a deliberate second
step so you see its credential prompts coming. If the destination exists,
`dev clone` errors and points at `dev cd`. Without the shell wrapper
active, the clone still happens and dev prints the destination instead of
jumping there.

## Tab completion

Completion follows the command tree: `dev <Tab>` offers the commands
available here, project commands included; `dev plan <Tab>` offers a
group's children; a leaf offers its own candidates (`dev runner unregister
<Tab>` lists this host's enrollments). `dev cd <Tab>` fills the argument
only and inserts `org/repo` when a short name would collide.

Per shell: zsh gets a menu-select list scoped to `dev` (skipped quietly if
your zshrc never runs `compinit`); bash fills `COMPREPLY`; fish registers a
pager completion and applies its own filtering, so fuzzy tokens may only
complete literally there.

## dev cred

```bash
dev cred get <namespace> <key>
```

Resolves a credential through the provider chain — environment, keychain,
file, prompt — and prints it. A non-interactive miss errors with `gh secret
set` guidance. Scripts call this instead of embedding lookup logic;
integrations read their credentials the same way (`wwise/email`,
`rubygems/api_key`, `steam/username`).
