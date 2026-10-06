#!/bin/sh
# Install dev-core at an exact version inside a dev-managed build container.
#
# Run by the host's dev (Dev::ContainerDevProvisioner) through `docker exec`
# when the container's `dev version` differs from the host's — never by
# hand, never at image build. The tap only ever carries the latest formula,
# so the exact version comes from the tap's history: the commit whose
# Formula/dev-core.rb points at v<version>.tar.gz is checked out and
# installed from. Linuxbrew is already in the image (the bootstrap installed
# the build group with it and removed only dev-core); brew allows root
# inside a container (/.dockerenv).
#
# Usage: sh container-provision-dev.sh <version>
set -eu

version="$1"
if [ -z "$version" ]; then
  echo "dev: container-provision-dev.sh: a version is required" >&2
  exit 2
fi

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

if ! command -v brew >/dev/null 2>&1; then
  echo "dev: no brew in this container — the image must carry Linuxbrew (bin/docker-install-build-deps.sh)" >&2
  exit 1
fi

tap_dir="$(brew --repo d3mlabs/d3mlabs)"
if [ ! -d "$tap_dir/.git" ]; then
  brew tap --quiet d3mlabs/d3mlabs
fi

# The tap may be owned by another user than the one exec'ing (root over a
# linuxbrew-owned prefix); git refuses such repos without this.
git_tap() {
  git -c safe.directory='*' -C "$tap_dir" "$@"
}

git_tap fetch --quiet origin

asset="v${version}.tar.gz"
sha=""
for candidate in $(git_tap log --all --format=%H -S"$asset" -- Formula/dev-core.rb); do
  if git_tap show "$candidate:Formula/dev-core.rb" | grep -q "$asset"; then
    sha="$candidate"
    break
  fi
done
if [ -z "$sha" ]; then
  echo "dev: the d3mlabs/d3mlabs tap has no dev-core formula for ${version}" >&2
  exit 1
fi

git_tap checkout --quiet "$sha"

# reinstall, not uninstall + install: brew autoremoves a formula's
# dependencies when the formula goes (gh, git, go, perl, rbenv, ruby-build,
# shadowenv, … — ~30 bottles for dev-core), then install pours them all
# back. reinstall swaps dev-core for the checked-out formula's version and
# leaves the dependency kegs in place. It handles a downgrade too, which
# upgrade would refuse.
if brew list --versions dev-core >/dev/null 2>&1; then
  brew reinstall --quiet d3mlabs/d3mlabs/dev-core
else
  brew install --quiet d3mlabs/d3mlabs/dev-core
fi

installed="$(dev version)"
if [ "$installed" != "$version" ]; then
  echo "dev: installed dev-core reports ${installed}, expected ${version}" >&2
  exit 1
fi
