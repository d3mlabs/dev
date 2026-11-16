---
name: default-is-the-converger-input
description: >-
  MUST be used when a reader (status, a remedy string, `--help`, a second
  bootstrap) needs a fact a converger established on the host — a user's
  name, a prefix's owner, an enrollment's scope — and is about to take the
  converger's default constant or flag for it.
---

# A default is the converger's input; the converged fact is the record

dev records nothing it can inspect ("inspected, never recorded"), which
only holds if every reader derives the fact from what the converger
*wrote* — the prefix's owner after the chown, the keg's realpath, the
`.runner` record's URL — and never from what the converger *started with*:
a `DEFAULT_NAME`, a standard prefix, a flag nobody re-passes. The default
describes a blank host; after one run it is stale by construction, and a
reader built on it is right only where the operator took every default.
Name the derivation once, beside the converger (`RunnerUser.host_name`,
`Settings.brew_prefix`), and have every reader — and every by-hand command
it prints — go through it.

Wrong — the default stood in for the identity on every host:

    host_identity: RunnerUser.for_host            # name: DEFAULT_NAME
    "sudo -iu #{RunnerUser::DEFAULT_NAME} dev up"  # the docs' escape hatch: "unless --as"

Right — the hand-over wrote the record; the reader reads it:

    RunnerUser.host_name(prefix:, owner_of:, operator:)   # the prefix's owner, unless it is the caller
    identity.host_up_command                                # spelled from the resolved name

The tell is an "unless …" caveat beside a printed command, or a status
line that is red only on hosts registered with a flag. The same shape put
four prefix resolvers beside the one keg fact (dev#568) before it put the
default name beside the prefix's owner (dev#613).

learned-from: dev#613 (status on an `--as` host reported the default
user; by-hand commands hardcoded `runner`), dev#568 the earlier instance.
date: 2026-11-16
