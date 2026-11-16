---
name: shipped-workflow-verbatim
description: >-
  MUST be used when adding a workflow dev ships under share/workflows, a
  verb that needs a project to carry one, or a repo-specific value a shipped
  workflow would otherwise hard-code.
---

# A shipped workflow is copied verbatim; a repo's fact is a variable or an input

A workflow dev ships (`share/workflows/*.yml`) is one file every adopting
project commits byte-for-byte at `.github/workflows/<name>`. Anything that
differs per repo — a runner label, a rubygems.org owner — enters as a
`workflow_dispatch` input or a repository/organization variable (`vars.*`),
read from the environment inside the step, never as an edit to the copy
and never as a hard-coded value. The verb that needs the copy checks for it
through `Lifecycle::ShippedWorkflow` and refuses with the `cp` named, so
every shipped workflow has one path and one refusal shape.

Wrong — a hand-rolled copy pins the repo's fact into the file, which no
other repo can take verbatim and dev cannot ship:

    env:
      RUBYGEMS_OWNER: "148200"   # one account, one repo

Right — the file stays generic; the repo sets a variable, the step reads it
and omits the field when unset:

    env:
      RUBYGEMS_OWNER: ${{ vars.RUBYGEMS_OWNER }}
    run: jq -n --arg owner "$RUBYGEMS_OWNER" '{jwt: $jwt} + (if $owner == "" then {} else {owner: $owner} end)'

A copy that drifts is what the three rubocop-d3mlabs publish failures
looked like; verbatim is what lets dev's own copy be the fix.

learned-from: dev#609 (`dev-publish-rubygems.yml` generalised from
rubocop-d3mlabs's hand-rolled `release.yml`; `ShippedWorkflow` extracted from
`LifecycleWorkflow` as the second shipped file arrived)
date: 2026-11-16
