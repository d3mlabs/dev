# typed: false
# frozen_string_literal: true

# The xcode integration's own manifest: the tooling XcodeIntegration shells
# to, in the same DSL a project uses. Ungrouped, so it exports: a project
# that pins an Xcode gets these locked into its own deps.lock with
# provenance (needed_by: xcode), in the scope of its xcode declaration, and
# installed before the xcode batch (ADR-0011).
require "dev/deps"

Dev::Deps.define do
  # The CLI that downloads and installs Xcode bundles. A macOS tool for a
  # macOS toolchain: the host gate keeps a Linux box that merely resolves
  # the lock from ever installing it.
  brew "xcodes", host: :darwin
end
