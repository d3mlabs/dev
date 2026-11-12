---
name: record-over-derivation
description: >-
  MUST be used when dev decides whether two things are the same — a
  local enrollment and a remote registration, a dir and a runner, a host
  and a slot — or when a name, label, directory name or hostname is about
  to be parsed to recover who owns what.
---

# Record over derivation

Identity is the id the record already carries — `.runner`'s `agentId`
and `poolName`, GitHub's `Runner#id` — never something derived from a
name, a label, a directory name or a hostname. Derivations are display
hints and collision-rate tuning; the moment one gates a destructive path
(retire, `--replace`, unregister) it is a steal waiting for a look-alike:
another host with the same hostname, a hand-named dir, a renamed runner.

```ruby
# WRONG: ownership derived from the name we would have generated
replace = own_names.include?(holder.name)

# RIGHT: ownership is the id in our record matching the id GitHub holds
replace = own.any? { |e| e.name == holder.name && e.agent_id == holder.id }
```

Check the id before any retire or enroll step runs, not after: a
look-alike must be refused with nothing torn down. When no id exists yet
(first enrollment), there is nothing to be "ours" — refuse the collision
and name the way beside it.

The shape recurs: dev#557 keyed on `<hostname>-<label>`, dev#565's first
cut keyed on the name family, both treating a derivation as identity.

learned-from: d3mlabs/dev#557 → d3mlabs/dev#565 (both cuts, fixed in
dev#580 by `Enrollment#agent_id`) → d3mlabs/dev#566 (`poolName` replaces
name parsing).
date: 2026-11-11
