#!/bin/sh
# Give a dev-managed build container's user the uid and gid that own its
# data root mount, so the container can write it. Under ADR-0008 the data
# root is a volume docker initialised as the image's own user, and this
# script is not reached; it remains for a mount owned by another uid.
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
# stay consistent. The mounts are not ours to re-own — the project bind
# mount, the data root (on Linux the host's own directory), the Linuxbrew
# volume, /proc and /sys — and -xdev alone does not keep the sweep off
# them: it stops find *descending* into a mount, but the mount point's own
# directory entry is still visited, and that inode is the mounted
# filesystem's root (the host's /var/lib/dev, re-owned to the runner user
# on the first realign; dev#310). So every mount point in this mount
# namespace, read from /proc/self/mountinfo, is pruned outright.
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
#
# Two seams for the test suite only: ALIGN_ROOT, a tree to treat as /
# (passwd, group, the Cellar and the sweep all under it), and
# ALIGN_MOUNTINFO, a mountinfo to read the mount points from.
set -eu

if [ "$#" -ne 6 ]; then
  echo "dev: container-align-user.sh: expected <user> <group> <old uid> <old gid> <uid> <gid>" >&2
  exit 2
fi
user="$1"; group="$2"; old_uid="$3"; old_gid="$4"; uid="$5"; gid="$6"
root="${ALIGN_ROOT:-}"
mountinfo="${ALIGN_MOUNTINFO:-/proc/self/mountinfo}"

# In place through a copy, not sed -i: GNU and BSD sed disagree on -i's
# argument, and the file keeps its inode and mode.
edit() {
  sed "$1" "$2" > "$2.align" && cat "$2.align" > "$2" && rm -f "$2.align"
}
edit "s/^$user:\([^:]*\):$old_uid:$old_gid:/$user:\1:$uid:$gid:/" "$root/etc/passwd"
edit "s/^$group:\([^:]*\):$old_gid:/$group:\1:$gid:/" "$root/etc/group"

cellar="$root/home/linuxbrew/.linuxbrew/Cellar"

# Every mount point but / itself (mountinfo field 5), as find -path terms.
set -- -false
while IFS=' ' read -r _ _ _ _ mount_point _; do
  case "$mount_point" in
    /) ;;
    *) set -- "$@" -o -path "$root$mount_point" ;;
  esac
done < "$mountinfo"

# One walk for both ids, in POSIX find (no GNU `,`): `-exec … +` is always
# true, so `! -user X -o -exec …` runs the chown exactly when the user
# matches and lets evaluation continue to the group test. -user/-group take
# numeric ids on GNU, BusyBox and BSD find alike (-uid/-gid are GNU-only);
# the old ids no longer resolve to a name once passwd is edited. The leading
# -prune drops the mount points and the regular files under the Cellar
# before either ownership test sees them.
find "${root:-/}" -xdev \( \( "$@" \) -o \( -type f -path "$cellar/*" \) \) -prune -o \
  \( ! -user "$old_uid" -o -exec chown -h "$uid" {} + \) \
  \( ! -group "$old_gid" -o -exec chgrp -h "$gid" {} + \)
