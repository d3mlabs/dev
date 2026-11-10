---
name: probe-at-the-owning-identity
description: >-
  MUST be used when register, status or a bootstrap step probes a host fact
  (a binary resolves, a login exists, a prefix is writable, a tap is
  trusted) on a host with more than one identity — operator, runner user,
  agent — or when a probe is a `which`, a bare `brew`, or a read of the
  calling process's PATH, cwd or env.
---

# Probe a fact where its owning identity holds it, never through the caller's environment

`dev runner register` and `dev runner status` run as the operator, but on
a Linux dev host the facts they check belong to other identities: the
brew prefix and its binaries are the runner user's, the gh login is the
runner user's, the tap trust file is the agent's. A probe that consults the
operator's process — `which`, PATH, cwd, `~` — answers for the operator,
not for the identity the fact is about; it is right on a Mac by accident
(one person is both) and wrong on the box. Address the fact at its owner:
the path the contract names (`<prefix>/bin/<tool>`), or the command run
as that user (`sudo -n -u <user> …`, from `/`), and report a refusal as
the finding rather than a prompt or a false "absent".

Wrong — the enrolling shell's PATH decides whether the agent CLI exists:

    return if @executor.quiet?("which", "cursor-agent")

Right — the channel's landing spot, derived from the brew the bootstrap
already discovered:

    path = File.join(File.dirname(brew), AGENT_CLI)   # <prefix>/bin/cursor-agent
    return if File.executable?(path)

Same rule, same repo: the prefix owner is stat'd, never assumed (dev#337);
login facts are asked as the runner user with `sudo -n` (dev#348); every
as-user command starts from `/` because sudo keeps the operator's cwd
(dev#493).

learned-from: dev#547 (the agent CLI check on Linux), after dev#337, dev#348, dev#493.
date: 2026-11-09
