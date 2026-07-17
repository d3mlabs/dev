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
# dev itself installs from the Homebrew tap — the latest *release*, the same
# channel every other consumer uses. Set DEV_REF to a d3mlabs/dev branch or
# tag to run from a source clone instead (escape hatch for iterating on dev
# before a release).
#
# This is NOT a user-facing CLI command. It runs inside docker build only.

set -euo pipefail

DEPS_DIR="${1:-/app}"
DEV_REF="${DEV_REF:-}"

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

if [ -n "$DEV_REF" ]; then
  echo ">>> Cloning d3mlabs/dev (${DEV_REF}) — source override"
  git clone --depth 1 --branch "$DEV_REF" https://github.com/d3mlabs/dev.git /tmp/dev
  DEV_HOME=/tmp/dev
else
  echo ">>> Installing dev (latest release from the d3mlabs tap)"
  brew install --quiet d3mlabs/d3mlabs/dev
  # The formula lays the tree out under libexec/dev with vendored gems in
  # libexec (see homebrew-d3mlabs/Formula/dev.rb); mirror its wrapper env so
  # the keg's scripts resolve their gems.
  DEV_HOME="$(brew --prefix dev)/libexec/dev"
  export GEM_HOME="$(brew --prefix dev)/libexec"
  export GEM_PATH="$GEM_HOME"
fi

echo ">>> Installing build dependencies from ${DEPS_DIR}/dependencies.rb"
ruby -I "$DEV_HOME/lib" -I "$DEV_HOME/src" "$DEV_HOME/bin/install-build-deps.rb" "$DEPS_DIR"

echo ">>> Cleaning up"
rm -rf /tmp/dev

echo ">>> Done"
