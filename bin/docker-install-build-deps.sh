#!/bin/bash
# Internal script for Dockerfiles: installs Linuxbrew and the :build group's
# brew dependencies from build-deps.lock into the image.
#
# Usage in Dockerfile:
#   COPY dev.yml dependencies.rb build-deps.lock /app/
#   RUN curl -fsSL https://raw.githubusercontent.com/d3mlabs/dev/main/bin/docker-install-build-deps.sh \
#         -o /tmp/install-build-deps.sh && bash /tmp/install-build-deps.sh
#
# Optional: pass the directory holding those files as $1 (default: /app).
# deps.lock is deliberately not copied: the build install never reads it,
# and copying it would invalidate this (slow, Linuxbrew) layer on every
# runtime-dependency change.
#
# The install is `dev deps install --group build --integration brew`, run
# by the latest dev *release* from the Homebrew tap — the same channel every
# other consumer uses, so the image reads the lock exactly as the host does
# (versioned formulae, taps). brew only: a :build group also pins host-
# installed artifacts (e.g. a gh engine release) that are volume-mounted into
# the container, never baked into the image. dev-core is uninstalled
# afterwards: dev is live infrastructure, and a copy frozen into an image
# layer would be a stale dev waiting to be run by accident (README: "dev is
# live infrastructure").
#
# This is NOT a user-facing CLI command. It runs inside docker build only.

set -euo pipefail

DEPS_DIR="${1:-/app}"

for required in dev.yml build-deps.lock; do
  if [ ! -f "${DEPS_DIR}/${required}" ]; then
    echo "docker-install-build-deps.sh: ${DEPS_DIR}/${required} not found." >&2
    echo "The Dockerfile must copy the project's dev manifests before this step:" >&2
    echo "  COPY dev.yml dependencies.rb build-deps.lock ${DEPS_DIR}/" >&2
    exit 1
  fi
done

# Homebrew's Linux build sandbox (Bubblewrap) requires unprivileged user
# namespaces, which aren't available inside docker build. The container
# already provides that isolation, so disable the redundant sandbox.
export HOMEBREW_NO_SANDBOX_LINUX=1

echo ">>> Installing Linuxbrew"
# Pinned to a Homebrew/install commit rather than HEAD: this pipes
# third-party code to bash inside every image build, and HEAD is a mutable
# ref an upstream compromise could repoint (dev#99). The repo publishes no
# tags, so the pin is a commit SHA; bump it deliberately when a newer
# installer is needed — a stale pin still installs current Homebrew.
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/24173182915f24bdd52a22fd073e421953b2a252/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# dev requires Ruby >= 3.1; distro rubies are often older (Ubuntu 22.04 ships
# 3.0). Homebrew's ruby is keg-only, hence the explicit PATH prepend.
echo ">>> Installing Ruby"
brew install --quiet ruby
export PATH="$(brew --prefix ruby)/bin:$PATH"

# Current Homebrew refuses to load formulae from untrusted third-party taps
# ("Refusing to load formula ... from untrusted tap"). Everything below
# installs from the d3mlabs tap — dev itself on the release channel, and
# :build deps like wwise-cli — so tap and trust it up front. The || true
# keeps older brews working: they have no trust subcommand and no policy to
# satisfy, and if a trust-enforcing brew somehow skips it, the install below
# still fails loudly.
#
# Trust MUST precede tap: current brew evaluates a new tap's formulae at tap
# time and refuses to load them from an untrusted tap, failing the tap itself
# ("Cannot tap ...: invalid syntax in tap!") — so trusting afterwards never
# gets the chance to run. `brew trust` records trust by name before the tap
# exists.
echo ">>> Trusting the d3mlabs tap"
brew trust d3mlabs/d3mlabs || true
brew tap d3mlabs/d3mlabs

echo ">>> Installing dev-core (latest release from the d3mlabs tap)"
# dev-core is the tool; the `dev` formula is the org DEPLOYMENT (org config
# + a dependency edge on dev-core). Installing from the lock needs no org
# identity (no knowledge repo, no learnings sync), so install the tool
# directly.
brew install --quiet d3mlabs/d3mlabs/dev-core

echo ">>> Installing build dependencies from ${DEPS_DIR}/build-deps.lock"
# CI=true declares the env rather than detecting it: this script only ever
# runs inside a docker build, where no CI variable exists — it IS the ci
# install path by construction, so env: :ci entries install and env: :dev
# ones do not. The host OS is detected (linux), so host: :darwin entries
# skip themselves.
#
# DEV_PIN_TAPS=1 (the image build's reproducible mode) adds --pinned-taps:
# dev checks each formula's tap out at the commit build-deps.lock names
# (one commit, fetched alone — not homebrew-core's history) and brew
# installs from those checkouts instead of its moving API, so two builds
# of one lock install one toolchain. Off by default: the lock then verifies
# the versions brew's API produced, as every host install does.
PINNED_TAPS=()
if [ "${DEV_PIN_TAPS:-}" = "1" ]; then
  PINNED_TAPS=(--pinned-taps)
fi
(cd "$DEPS_DIR" && CI=true dev deps install --group build --integration brew ${PINNED_TAPS[@]+"${PINNED_TAPS[@]}"})

echo ">>> Removing dev-core from the image"
# The toolchain stays; dev leaves. Its brew dependencies (rbenv, shadowenv)
# remain as ordinary installed formulae.
brew uninstall --quiet dev-core

echo ">>> Done"
