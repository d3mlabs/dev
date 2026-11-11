---
name: ui-seam-ownership
description: >-
  MUST be used when putting a module on the `Dev::Ui` seam (an integration,
  publisher, gc, container step) or migrating its tests off `out.string`
  greps — who owns the frame, which call is a step vs a spin, and what
  silence means.
---

# The coordinator frames; the unit of work speaks inside; nothing says nothing

The orchestrator that dispatches a batch owns the `frame` (one per
integration that does work); the unit inside speaks only `step`, `spin`
and `note` through its own `@ui`, and a unit with nothing to do emits no
row at all. A child that may take the terminal — anything that can prompt
(sudo, brew bundle, steamcmd, an installer) — is a `step`; a `spin` is
only for a call whose output is captured and parsed in-process.

Wrong — the integration frames itself and spins a child that may prompt:

    @ui.frame("brew") do
      @ui.spin("Installing llvm") { system(*escalation, brew, "install", "llvm") }
    end

Right (dev#573): `Installer#dispatch` frames `"brew: 3 pins"`; inside,
`BrewIntegration#announce` picks the verb from the fact that decides it —
`escalation.empty? ? spin(name) : step("#{name} (sudo -u owner)")` — and
satisfied pins fold into one `{{v}} … already installed` note. Facts carry
their glyph in cli-ui markup (`{{v}}`, `{{x}}`), never a `>>>` prefix;
`NoUi` renders them plain through a pipe. Tests assert the sequence —
`ui.rows == [[:step, "Registering the tap x", 0], [:spin, …, 0]]` — and
a warm pass asserts `ui.rows == []`, never `out.string.include?`. A
question (`confirm`, `ask_secret`) answers `nil` under `NoUi`: the caller
refuses with the headless hint, so a pipe never hangs on a prompt.

learned-from: dev#573 build pass (deps on the Ui seam; plans#52 step 2)
date: 2026-11-11
