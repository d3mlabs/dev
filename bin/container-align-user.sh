#!/bin/sh
# Give a dev-managed build container's user the uid and gid that own the
# mounted data root — the host user's — so every bind mount is writable from
# inside and what the container writes belongs to the host user outside.
#
# Run as root by the host's dev (Dev::ContainerUserAligner) through
# `docker exec`, once, when the container's user cannot write /var/lib/dev —
# never by hand, never at image build. The image user's entry in /etc/passwd
# and its group's in /etc/group take the new ids (usermod refuses while the
# user owns a process, and pid 1 is that user's `sleep`; docker exec resolves
# the image USER name against these files at exec time, so the next exec runs
# as the new uid). Then what the old uid or gid held on the container's root
# filesystem is re-owned — by old id, not a path list, so Linuxbrew's
# prefix-ownership check and anything else the image created for that user
# stay consistent. -xdev keeps the sweep off the bind mounts (the host's
# project, data root and engine trees are not ours to re-own) and off /proc
# and /sys.
#
# Regular files inside Linuxbrew's Cellar are the one exception. On an
# overlay filesystem the first chown of a lower-layer file copies its whole
# contents into the container's writable layer, so the sweep costs bytes,
# not entries — and the Cellar is most of them (3.5 GB of 6 GB in the
# cellbound-3d image; the full sweep took a minute per cold container start,
# plans#48). Homebrew never writes into a poured keg: it adds and removes
# whole kegs and rewrites the symlinks in opt/ and bin/, all of which need
# the enclosing *directories* to be ours — and those are re-owned. The keg
# contents may stay with the old ids.
#
# Usage: sh container-align-user.sh <user> <group> <old uid> <old gid> <uid> <gid>
set -eu

if [ "$#" -ne 6 ]; then
  echo "dev: container-align-user.sh: expected <user> <group> <old uid> <old gid> <uid> <gid>" >&2
  exit 2
fi
user="$1"; group="$2"; old_uid="$3"; old_gid="$4"; uid="$5"; gid="$6"

sed -i "s/^$user:\([^:]*\):$old_uid:$old_gid:/$user:\1:$uid:$gid:/" /etc/passwd
sed -i "s/^$group:\([^:]*\):$old_gid:/$group:\1:$gid:/" /etc/group

cellar="/home/linuxbrew/.linuxbrew/Cellar"

# One walk for both ids. -user/-group take numeric ids on GNU and BusyBox
# find alike (-uid/-gid are GNU-only); the old ids no longer resolve to a
# name once passwd is edited. The leading -prune drops regular files under
# the Cellar before either ownership test sees them.
find / -xdev \( -type f -path "$cellar/*" -prune \) -o \
  \( \( -user "$old_uid" -exec chown -h "$uid" {} + \) , \( -group "$old_gid" -exec chgrp -h "$gid" {} + \) \)
