#!/bin/bash
# Run as root: sudo bash tools/setup_armbian_build_user.sh
#
# Provisions a dedicated, low-privilege user ("armbian-build") for running
# Armbian's native (non-Docker) ./compile.sh out of this checkout.
#
# IMPORTANT DIFFERENCE FROM THE samwise-build MODEL:
# Armbian's compile.sh does not shell out to individually-allowlistable
# commands. When run as a non-root user with Docker unavailable, it does
# `exec sudo --preserve-env ... bash compile.sh <same args>`
# (lib/functions/cli/utils-cli.sh) -- i.e. it re-execs the *entire build* as
# root, then does whatever mount/chroot/losetup/apt-get it needs internally,
# unconstrained. There is no fixed set of safe primitives to validate the
# way the apt-get wrapper does for samwise-build. The only real lever here
# is *which script* can be run as root, not what that script then does.
# So: sudo is restricted to invoking exactly this one script, at this one
# path, as opposed to a general apt-get/root grant.
set -euo pipefail

NEWUSER="armbian-build"
# This script lives at <repo>/tools/setup_armbian_build_user.sh; derive the
# repo root the same way compile.sh derives its own SRC, so this works
# regardless of whose home directory the repo is checked out in.
REPO_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
# Grant ACL access into whichever account's home directory actually owns
# this checkout, rather than assuming a fixed path depth under $HOME.
REPO_OWNER="$(stat -c '%U' "$REPO_DIR")"
OWNER_HOME="$(getent passwd "$REPO_OWNER" | cut -d: -f6)"
BASH_BIN="$(command -v bash)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo bash $0)" >&2
  exit 1
fi

if [ ! -d "$REPO_DIR" ] || [ ! -f "$REPO_DIR/compile.sh" ]; then
  echo "Expected an Armbian checkout with compile.sh at $REPO_DIR -- not found." >&2
  exit 1
fi

# 1. ACL support (usually already present on Ubuntu, but make sure)
apt-get install -y acl

# 2. Create the build user with its own home, no extra groups (not in sudo/adm/etc.)
if id "$NEWUSER" &>/dev/null; then
  echo "User $NEWUSER already exists, skipping useradd"
else
  useradd -m -s /bin/bash "$NEWUSER"
  echo "Created user $NEWUSER. Set a password for it (needed for sudo below):"
  echo "  sudo passwd $NEWUSER"
fi

# 3. Lock down other users' home dirs so armbian-build can't wander into them.
#    (Only touches dirs that are currently group/world readable; the repo
#    owner's home is handled separately via scoped ACL below, not group
#    membership.)
for d in /home/*; do
  u=$(basename "$d")
  if [ "$u" != "$NEWUSER" ] && [ "$u" != "$REPO_OWNER" ] && [ -d "$d" ]; then
    chmod o-rwx,g-rwx "$d"
    echo "Locked down $d (owner-only)"
  fi
done

# 4. Confirm the filesystem for /home is ACL-capable.
mount_point=$(df --output=target "$OWNER_HOME" | tail -1)
if ! mount | grep " $mount_point " | grep -q acl; then
  echo "NOTE: $mount_point may not have 'acl' explicitly in mount opts (often on by default for ext4 on modern kernels)."
  echo "If setfacl below fails with 'Operation not supported', add 'acl' to the mount options in /etc/fstab and remount."
fi

# 5. Grant armbian-build access to ONLY the Armbian repo, not all of the
#    repo owner's home (unlike samwise-build's whole-home grant). Parent
#    directories get execute-only ACLs so armbian-build can traverse into
#    the repo path without being able to list or read anything else there.
setfacl -m u:"$NEWUSER":x "$OWNER_HOME"
setfacl -m u:"$NEWUSER":x "$(dirname "$REPO_DIR")"
setfacl -R -m u:"$NEWUSER":rwX "$REPO_DIR"
setfacl -R -d -m u:"$NEWUSER":rwX "$REPO_DIR"   # default ACL: applies to new files/dirs created later
echo "Granted $NEWUSER traversal into ${OWNER_HOME} and $(dirname "$REPO_DIR"), and rwX on $REPO_DIR"

# 6. Sudo, restricted to launching this one script as root.
#    SETENV is required because compile.sh's self-relaunch uses
#    `sudo --preserve-env VAR=val ... bash compile.sh <args>` -- without
#    SETENV, sudo refuses to preserve/set env vars and the relaunch fails.
#    This does NOT limit what compile.sh does once running as root; it only
#    limits armbian-build to invoking this specific script via sudo.
SUDOERS_FILE="/etc/sudoers.d/${NEWUSER}-compile"
cat > "$SUDOERS_FILE" <<EOF
Cmnd_Alias ARMBIAN_BUILD = ${BASH_BIN} ${REPO_DIR}/compile.sh *
$NEWUSER ALL=(root) SETENV: ARMBIAN_BUILD
EOF
chmod 0440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE"
echo "Installed sudoers rule at $SUDOERS_FILE (only ${REPO_DIR}/compile.sh, password required)"

echo
echo "Done. Verify with:"
echo "  getfacl $REPO_DIR | head"
echo "  sudo -l -U $NEWUSER"
echo "  sudo -u $NEWUSER -i"
echo "    cd $REPO_DIR && ./compile.sh   # should prompt for armbian-build's sudo password on relaunch"
