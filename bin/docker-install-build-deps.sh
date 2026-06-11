#!/bin/bash
# Internal script for Dockerfiles: installs Linuxbrew and :build group
# dependencies from dependencies.rb into the image.
#
# Usage in Dockerfile:
#   COPY dependencies.rb /app/
#   RUN curl -fsSL https://raw.githubusercontent.com/d3mlabs/dev/main/bin/docker-install-build-deps.sh | bash
#
# Optional: pass the directory containing dependencies.rb as $1 (default: /app).
# Optional: set DEV_REF to the d3mlabs/dev branch or tag to clone (default: main).
#
# This is NOT a user-facing CLI command. It runs inside docker build only.

set -euo pipefail

DEPS_DIR="${1:-/app}"
DEV_REF="${DEV_REF:-main}"

# Homebrew's Linux build sandbox (Bubblewrap) requires unprivileged user
# namespaces, which aren't available inside docker build. The container
# already provides that isolation, so disable the redundant sandbox.
export HOMEBREW_NO_SANDBOX_LINUX=1

echo ">>> Installing Linuxbrew"
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# dev requires Ruby >= 3.1; distro rubies are often older (Ubuntu 22.04 ships
# 3.0). Homebrew's ruby is keg-only, hence the explicit PATH prepend.
echo ">>> Installing Ruby"
brew install --quiet ruby
export PATH="$(brew --prefix ruby)/bin:$PATH"

echo ">>> Cloning d3mlabs/dev (${DEV_REF})"
git clone --depth 1 --branch "$DEV_REF" https://github.com/d3mlabs/dev.git /tmp/dev

echo ">>> Installing build dependencies from ${DEPS_DIR}/dependencies.rb"
ruby -I /tmp/dev/lib -I /tmp/dev/src /tmp/dev/bin/install-build-deps.rb "$DEPS_DIR"

echo ">>> Cleaning up"
rm -rf /tmp/dev

echo ">>> Done"
