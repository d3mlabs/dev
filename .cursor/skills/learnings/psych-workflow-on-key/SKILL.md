---
name: psych-workflow-on-key
description: >-
  MUST be used when reading a GitHub workflow file (or any YAML keyed by
  `on`, `yes`, `no`, `off`) with Psych — a parser that looks under the
  string key silently finds nothing.
---

# Psych reads a workflow's `on:` key as `true`

Psych follows YAML 1.1, so an unquoted `on` key is the boolean `true`:
`YAML.safe_load("on:\n  push:")` is `{ true => { "push" => nil } }`, and
`document["on"]` is `nil` for every workflow written the way GitHub's
docs write them. A check such as "does this workflow have an `on: push`
trigger" then answers *no* for every file — a silent pass, the worst
failure shape for a guard. Only a quoted `"on":` arrives as the string.

Wrong — look under the string key only:

    on = document["on"]            # nil for `on:`; the guard never fires

Right — accept both spellings, say why in a comment:

    ON_KEYS = ["on", true].freeze  # Psych: bare `on` is YAML 1.1's boolean
    on = ON_KEYS.filter_map { |key| document[key] }.first

The same holds for `yes`/`no`/`off`/`y`/`n` keys; `permitted_classes`
and `safe_load` do not change it. A regression test must write the
trigger block unquoted (`on:\n  push:`), the way the files in the wild
are — a fixture with `"on":` proves nothing.

learned-from: dev#418 — `Dev::Lifecycle::WorkflowTriggers`, the
unfiltered-`on: push` refusal before a snapshot push, where the
string-keyed first draft would have waved every workflow through.
date: 2026-11-05
