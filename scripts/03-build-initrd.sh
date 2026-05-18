#!/bin/bash
set -euo pipefail

# Build an initramfs that is bootable on its own and pulls the live rootfs over
# HTTP via dracut's livenet + dmsquash-live modules. The casper initrd shipped
# in the Ubuntu live-server ISO is not standalone-bootable for our use case;
# dracut gives us a generic, minimal alternative.
#
# This script runs dracut on the host but uses the *target* Ubuntu kernel's
# modules (extracted into the rootfs by 02-customize-rootfs.sh) via --kmoddir.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO/work"
ROOTFS="$WORK/rootfs"
OUTDIR="$WORK/initrd"

mkdir -p "$OUTDIR"

if [ ! -d "$ROOTFS/usr/lib/modules" ]; then
    echo "[03-initrd] missing $ROOTFS/usr/lib/modules — run 02-customize-rootfs first" >&2
    exit 1
fi

KVER=$(ls "$ROOTFS/usr/lib/modules" | head -1)
if [ -z "$KVER" ]; then
    echo "[03-initrd] no kernel modules found in rootfs" >&2
    exit 1
fi
MODDIR="$ROOTFS/usr/lib/modules/$KVER"

echo "[03-initrd] Building dracut initramfs for kernel $KVER"

INITRD_OUT="$OUTDIR/initramfs.img"
rm -f "$INITRD_OUT"

# dracut needs to write to its tempdir as root, and we want predictable file
# ownerships in the image — so the build runs under sudo.
sudo dracut \
    --force \
    --kver "$KVER" \
    --kmoddir "$MODDIR" \
    --no-hostonly \
    --add "livenet dmsquash-live url-lib network kernel-network-modules" \
    --add-drivers "virtio_blk virtio_net virtio_pci virtio_console virtio_scsi loop overlay squashfs" \
    --compress=zstd \
    --reproducible \
    "$INITRD_OUT"

sudo chown "$(id -u):$(id -g)" "$INITRD_OUT"

ls -lh "$INITRD_OUT"
echo "[03-initrd] done"
