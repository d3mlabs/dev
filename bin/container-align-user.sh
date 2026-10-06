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
# as the new uid). Then every file the old uid or gid held on the container's
# root filesystem is re-owned — the whole filesystem by old id, not a path
# list, so Linuxbrew's prefix-ownership check and anything else the image
# created for that user stay consistent. -xdev keeps the sweep off the bind
# mounts (the host's project, data root and engine trees are not ours to
# re-own) and off /proc and /sys.
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

# -user/-group take numeric ids on GNU and BusyBox find alike (-uid/-gid are
# GNU-only); the old ids no longer resolve to a name once passwd is edited.
find / -xdev -user "$old_uid" -exec chown -h "$uid" {} +
find / -xdev -group "$old_gid" -exec chgrp -h "$gid" {} +
