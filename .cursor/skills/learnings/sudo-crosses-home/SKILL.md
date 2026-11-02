---
name: sudo-crosses-home
description: >-
  MUST be used when dev runs a command as another host identity (sudo -u
  the prefix owner, the runner user, the agent user), or when diagnosing a
  brew run that reports another user's `~/.homebrew`, cache, or brew.env.
---

# A sudo that crosses a user boundary crosses HOME too

Homebrew's state is per user and rooted at `$HOME`: the trust store
(`~/.homebrew/trust.json`, which brew 7 refuses unless its owner is the
running user), the download cache, `brew.env`. macOS sudo keeps the
caller's HOME (`env_keep += "HOME"`), so `sudo -u <other> brew …` runs as
one identity against another's state. Every user-crossing sudo dev emits
carries `-H` — the target's HOME — never just `-u`; a brew edge in
sudoers that names the binary by path still accepts `-H`.

Wrong — the escalated brew write (`BrewIntegration#escalation`) as the
prefix owner with the agent's HOME; brew 7's answer is `Refusing to write
insecure trust store: /Users/ai-agent/.homebrew is not owned by the
current user`, and every tap-sourced install stops:

    ["sudo", "-n", "-u", owner, *assignments, "/opt/homebrew/bin/brew", *args]

Right — the shape `RunnerUser#sudo_argv` and `SudoAgentExecutor` already
have:

    ["sudo", "-n", "-H", "-u", owner, *assignments, "/opt/homebrew/bin/brew", *args]

Per-user trust is the same rule from the other side (dev#310, dev#374):
each identity that runs brew *reads* with its own trust, so a bootstrap
trusts the tap for that identity (TapTrust) instead of borrowing the
operator's.

learned-from: dev#386 (`dev up` in a `/build` checkout refused by the
owner's brew reading the agent's trust store), the third per-user brew
state crossing after dev#310 and dev#374.
date: 2026-11-01
