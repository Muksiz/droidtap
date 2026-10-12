#!/bin/bash
# Runs as root: prepares devices and directories, then starts the services.
set -euo pipefail

as_droid() { setpriv --reuid droid --regid droid --init-groups "$@"; }

if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm is missing. The emulator needs KVM (nested virtualization" >&2
    echo "       in WSL2 on Windows). See README.md, 'Troubleshooting'." >&2
    exit 1
fi

# Give droid access to /dev/kvm. Hosts without udev (Docker Desktop's WSL VM)
# leave it root-only, so open up the container's own device node first; if
# that is not allowed (rootless engines), fall back to joining its group.
can_use_kvm() { as_droid test -r /dev/kvm -a -w /dev/kvm; }
if ! can_use_kvm; then
    chmod a+rw /dev/kvm 2> /dev/null || true
fi
if ! can_use_kvm; then
    kvm_gid=$(stat -c %g /dev/kvm)
    kvm_group=$(getent group "$kvm_gid" | cut -d: -f1 || true)
    if [ -z "$kvm_group" ]; then
        kvm_group=hostkvm
        groupadd -g "$kvm_gid" "$kvm_group"
    fi
    usermod -aG "$kvm_group" droid
fi
if ! can_use_kvm; then
    echo "ERROR: /dev/kvm exists but cannot be opened: $(ls -l /dev/kvm)" >&2
    exit 1
fi

# Leftovers from a previous run of this same container would block a restart.
rm -rf /tmp/.X0-lock /tmp/.X11-unix
install -d -m 1777 /tmp/.X11-unix

as_droid test -w /home/droid/.android || chown droid:droid /home/droid/.android

# supervisord stays root so it can attach the services' output to the
# container log (Docker refuses that to other users); every program in
# droid.conf runs as droid.
exec supervisord -c /etc/supervisor/droid.conf
