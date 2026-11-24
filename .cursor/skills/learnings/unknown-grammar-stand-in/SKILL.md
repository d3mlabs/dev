---
name: unknown-grammar-stand-in
description: MUST be used when a test needs a declaration this dev "cannot read" — an unknown dev.yml key, an unknown packager option, a lock field this version predates — to exercise a deferral, fault or refusal path.
---

# A stand-in for the unknown must stay unknown

A test that exercises "this dev predates the key" picks a key that will
never become vocabulary — a nonsense one (`level: 9`) — not the next
option on the roadmap. The moment the roadmap option ships, the fixture
parses, the fault is nil, and the test errors on something unrelated
(`undefined method 'message' for nil`) in the PR that had nothing to do
with it.

```ruby
# WRONG: the stand-in is the feature the next issue ships
packager: { archive: { files: [bin, lib] } }      # dev#687 made this read
manifest.lifecycle_fault.message == "archive takes format, split, vendor, not files"

# RIGHT: the stand-in is a key no issue will ever add
packager: { archive: { files: [bin, lib], level: 9 } }
manifest.lifecycle_fault.message == "archive takes format, split, vendor, files, not level"
```

If the refusal message lists the known set, the assertion still tracks
the set as it grows; that is fine — the point is that the *unknown* side
stays unknown.

learned-from: dev#692 — the dev#689 fixtures in `project_manifest_loader_test.rb` and `runner_test.rb` used `files:` as the option "ahead of this dev"; dev#687 shipped `files:` and both tests erred on `nil.message` in the next unrelated PR.
date: 2026-11-24
