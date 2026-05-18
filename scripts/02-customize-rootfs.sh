#!/bin/bash
set -euo pipefail

# Customizing the rootfs requires recording file ownership for users we are
# not (such as root, sshd, daemon, _apt). We use fakeroot for that. There is
# no real chroot here: instead of running apt-get inside the rootfs (which
# would need either user-namespaces or a working fakechroot — neither is
# reliable inside a rootless container) we assemble the rootfs by merging
# the base layer, the server layer, and a curated subset of paths from the
# Subiquity-installer layer (which is where openssh-server lives in the
# Ubuntu live-server image).
if [ "${IN_FAKEROOT:-0}" != "1" ]; then
    export IN_FAKEROOT=1
    exec fakeroot -- "$0" "$@"
fi

: "${SQUASHFS_OUTPUT:?}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO/work"
CASPER="$WORK/casper"
ROOTFS="$WORK/rootfs"
DIST="$REPO/dist"

mkdir -p "$DIST"

SQFS_BASE="$CASPER/ubuntu-server-minimal.squashfs"
SQFS_SERVER="$CASPER/ubuntu-server-minimal.ubuntu-server.squashfs"
SQFS_INSTALLER="$CASPER/ubuntu-server-minimal.ubuntu-server.installer.squashfs"
SQFS_OUT="$DIST/$SQUASHFS_OUTPUT"

for s in "$SQFS_BASE" "$SQFS_SERVER" "$SQFS_INSTALLER"; do
    if [ ! -s "$s" ]; then
        echo "[02-rootfs] missing source layer: $s — run 01-fetch first" >&2
        exit 1
    fi
done

# fakeroot virtualizes st_nlink for files created within its session. We need
# the real on-disk link count to identify casper's "no-change" markers, so
# strip LD_PRELOAD when calling find for that purpose.
NOFAKE='env -u LD_PRELOAD -u FAKEROOTKEY'

prune_markers() {
    local dir="$1"
    local before after
    before=$($NOFAKE find "$dir" -size 0 -type f -links +1 2>/dev/null | wc -l)
    echo "[02-rootfs]   $before marker paths"
    $NOFAKE find "$dir" -size 0 -type f -links +1 -delete 2>/dev/null || true
    after=$($NOFAKE find "$dir" -size 0 -type f -links +1 2>/dev/null | wc -l)
    if [ "$after" != "0" ]; then
        echo "[02-rootfs]   WARNING: $after markers remained after delete" >&2
    fi
}

echo "[02-rootfs] Cleaning previous rootfs and staging dirs"
for d in "$ROOTFS" "$WORK/srv-layer" "$WORK/installer-layer"; do
    if [ -d "$d" ]; then
        chmod -R u+w "$d" 2>/dev/null || true
        rm -rf "$d"
    fi
done

echo "[02-rootfs] Unsquashing base layer: $(basename "$SQFS_BASE")"
unsquashfs -no-progress -d "$ROOTFS" "$SQFS_BASE" >/dev/null

echo "[02-rootfs] Unsquashing server layer to staging"
SRV_STAGE="$WORK/srv-layer"
unsquashfs -no-progress -d "$SRV_STAGE" "$SQFS_SERVER" >/dev/null

echo "[02-rootfs] Pruning casper no-change markers from server layer"
prune_markers "$SRV_STAGE"

echo "[02-rootfs] Merging server layer onto base"
rsync -aHAX "$SRV_STAGE/" "$ROOTFS/"
chmod -R u+w "$SRV_STAGE"
rm -rf "$SRV_STAGE"

echo "[02-rootfs] Unsquashing installer layer to staging (for openssh-server)"
INST_STAGE="$WORK/installer-layer"
unsquashfs -no-progress -d "$INST_STAGE" "$SQFS_INSTALLER" >/dev/null

echo "[02-rootfs] Pruning casper no-change markers from installer layer"
prune_markers "$INST_STAGE"

echo "[02-rootfs] Cherry-picking openssh-server from installer layer"
# Only copy SSH-related files from the installer layer. We deliberately skip
# everything else (subiquity, snap mounts, casper-md5check) so the resulting
# rootfs boots into a plain shell, not the installer UI.
rsync -aHAX \
    --include='/usr/' \
    --include='/usr/sbin/' \
    --include='/usr/sbin/sshd' \
    --include='/usr/sbin/sshd-keygen' \
    --include='/usr/lib/' \
    --include='/usr/lib/openssh/' \
    --include='/usr/lib/openssh/**' \
    --include='/usr/lib/sftp-server' \
    --include='/usr/lib/systemd/' \
    --include='/usr/lib/systemd/system/' \
    --include='/usr/lib/systemd/system/ssh.service' \
    --include='/usr/lib/systemd/system/ssh.socket' \
    --include='/usr/lib/systemd/system/ssh@.service' \
    --include='/usr/lib/systemd/system/sshd.service' \
    --include='/usr/lib/systemd/system/sshd@.service' \
    --include='/usr/lib/systemd/system/sshd-keygen.service' \
    --include='/usr/lib/systemd/system/sshd-keygen@.service' \
    --include='/usr/lib/systemd/system-generators/' \
    --include='/usr/lib/systemd/system-generators/sshd-socket-generator' \
    --include='/usr/share/' \
    --include='/usr/share/openssh/' \
    --include='/usr/share/openssh/**' \
    --include='/usr/lib/x86_64-linux-gnu/' \
    --include='/usr/lib/x86_64-linux-gnu/libwrap.so.*' \
    --include='/etc/' \
    --include='/etc/ssh/' \
    --include='/etc/ssh/sshd_config' \
    --include='/etc/ssh/sshd_config.d/' \
    --include='/etc/ssh/sshd_config.d/**' \
    --include='/etc/pam.d/' \
    --include='/etc/pam.d/sshd' \
    --include='/etc/default/' \
    --include='/etc/default/ssh' \
    --include='/etc/init.d/' \
    --include='/etc/init.d/ssh' \
    --include='/etc/systemd/' \
    --include='/etc/systemd/system/' \
    --include='/etc/systemd/system/ssh.service.wants/' \
    --include='/etc/systemd/system/ssh.service.wants/**' \
    --include='/etc/systemd/system/ssh.service.requires/' \
    --include='/etc/systemd/system/ssh.service.requires/**' \
    --include='/etc/systemd/system/ssh.socket.wants/' \
    --include='/etc/systemd/system/ssh.socket.wants/**' \
    --include='/etc/systemd/system/sshd.service.wants/' \
    --include='/etc/systemd/system/sshd.service.wants/**' \
    --include='/etc/systemd/system/sshd@.service.wants/' \
    --include='/etc/systemd/system/sshd@.service.wants/**' \
    --exclude='*' \
    "$INST_STAGE/" "$ROOTFS/"

echo "[02-rootfs] Pre-generating SSH host keys"
# We can't run sshd-keygen.service inside fakeroot, and ConditionFirstBoot is
# fragile in a live overlay. Bake the host keys into the squashfs.
mkdir -p "$ROOTFS/etc/ssh"
ssh-keygen -A -f "$ROOTFS" >/dev/null
chmod 600 "$ROOTFS/etc/ssh/"*_key
chmod 644 "$ROOTFS/etc/ssh/"*_key.pub

echo "[02-rootfs] Adding sshd system user"
# These are the canonical openssh-server uid/gid expectations.
if ! grep -q '^sshd:' "$ROOTFS/etc/passwd"; then
    echo 'sshd:x:983:65534:sshd user:/run/sshd:/usr/sbin/nologin' >> "$ROOTFS/etc/passwd"
fi
if ! grep -q '^sshd:' "$ROOTFS/etc/shadow" 2>/dev/null; then
    echo 'sshd:!*:20563::::::' >> "$ROOTFS/etc/shadow"
fi
chmod -R u+w "$INST_STAGE"
rm -rf "$INST_STAGE"

echo "[02-rootfs] Copying overlay/"
if [ -d "$REPO/overlay" ]; then
    rsync -aHAX --chown=root:root "$REPO/overlay/" "$ROOTFS/"
fi

echo "[02-rootfs] Installing authorized_keys"
mkdir -p "$ROOTFS/root/.ssh"
chmod 700 "$ROOTFS/root/.ssh"
if [ -f "$REPO/keys/authorized_keys" ]; then
    grep -v '^[[:space:]]*#' "$REPO/keys/authorized_keys" \
        | grep -v '^[[:space:]]*$' > "$ROOTFS/root/.ssh/authorized_keys" || true
    chmod 600 "$ROOTFS/root/.ssh/authorized_keys"
fi
if [ ! -s "$ROOTFS/root/.ssh/authorized_keys" ]; then
    echo "[02-rootfs] WARNING: no SSH keys in keys/authorized_keys — root login will be impossible without cloud-init providing keys" >&2
fi

echo "[02-rootfs] Enabling services via systemd symlinks"
# We cannot run `systemctl enable` from outside the rootfs; instead we create
# the wants/requires symlinks by hand. ssh.socket is the socket-activated
# entry point on Ubuntu 22.04+; ssh.service is its accept handler.
mkdir -p \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants" \
    "$ROOTFS/etc/systemd/system/sockets.target.wants"

link_if_target() {
    local target="$1" link_dir="$2" link_name="$3"
    if [ -e "$ROOTFS$target" ]; then
        ln -sf "$target" "$ROOTFS/etc/systemd/system/$link_dir/$link_name"
    fi
}
link_if_target /usr/lib/systemd/system/ssh.service       multi-user.target.wants ssh.service
link_if_target /usr/lib/systemd/system/ssh.socket        sockets.target.wants    ssh.socket
# sshd-keygen runs `ssh-keygen -A` on first boot to populate /etc/ssh/ssh_host_*_key.
# Without it sshd fails its config check (ExecStartPre=sshd -t) and the socket-
# activated service refuses every connection with RST.
link_if_target /usr/lib/systemd/system/sshd-keygen.service multi-user.target.wants sshd-keygen.service
link_if_target /usr/lib/systemd/system/cloud-init.service       multi-user.target.wants cloud-init.service
link_if_target /usr/lib/systemd/system/cloud-config.service     multi-user.target.wants cloud-config.service
link_if_target /usr/lib/systemd/system/cloud-final.service      multi-user.target.wants cloud-final.service
link_if_target /usr/lib/systemd/system/cloud-init-local.service multi-user.target.wants cloud-init-local.service

echo "[02-rootfs] Removing artifacts that should not be in the live rootfs"
rm -rf \
    "$ROOTFS/var/cache/apt/archives/"*.deb \
    "$ROOTFS/var/lib/apt/lists/"* \
    "$ROOTFS/tmp/"* \
    "$ROOTFS/var/tmp/"* \
    2>/dev/null || true

echo "[02-rootfs] Building squashfs $SQFS_OUT"
rm -f "$SQFS_OUT"
mksquashfs "$ROOTFS" "$SQFS_OUT" \
    -comp zstd -Xcompression-level 19 \
    -no-progress -noappend \
    -wildcards \
    -e 'tmp/*' 'var/tmp/*' 'var/cache/apt/archives/*'

ls -lh "$SQFS_OUT"
echo "[02-rootfs] done"
