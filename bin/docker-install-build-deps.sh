#!/bin/bash
# Internal script for Dockerfiles: installs Linuxbrew and :build group
# dependencies from dependencies.rb into the image.
#
# Usage in Dockerfile:
#   COPY dependencies.rb /app/
#   RUN curl -fsSL https://raw.githubusercontent.com/d3mlabs/dev/main/bin/docker-install-build-deps.sh | bash
#
# Optional: pass the directory containing dependencies.rb as $1 (default: /app).
#
# This is NOT a user-facing CLI command. It runs inside docker build only.

set -euo pipefail

DEPS_DIR="${1:-/app}"

echo ">>> Installing Linuxbrew"
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

echo ">>> Cloning d3mlabs/dev"
git clone --depth 1 https://github.com/d3mlabs/dev.git /tmp/dev

echo ">>> Installing build dependencies from ${DEPS_DIR}/dependencies.rb"
ruby -I /tmp/dev/lib -I /tmp/dev/src /tmp/dev/bin/install-build-deps.rb "$DEPS_DIR"

echo ">>> Cleaning up"
rm -rf /tmp/dev

echo ">>> Done"
