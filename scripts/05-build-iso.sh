#!/bin/bash
set -euo pipefail

# Wrap dist/filesystem.squashfs into a minimal ISO-9660 image so the squashfs
# can be served to the *stock casper initrd* from the upstream live ISO, not
# the dracut initramfs that 03-build-initrd.sh builds.
#
# Why both paths coexist:
#   - The UKI path (03+04) is the intended design: a self-contained dracut
#     initramfs that pulls filesystem.squashfs directly over HTTP.
#   - On some BMaaS deployments (CoreWeave POC4EE B200 nodes at the time of
#     writing) the UKI is unused — the deployer serves work/casper/vmlinuz
#     and work/casper/initrd separately via iPXE. That initrd is casper, and
#     casper does not accept a raw squashfs URL: do_urlmount runs
#     `wget URL -O ubuntu26.iso && mount -o ro ubuntu26.iso /cdrom` and then
#     calls is_casper_path which looks for /cdrom/casper/*.squashfs. So we
#     need an ISO with that layout.
#
# Additional details:
#   - -partition_offset 16 places an MBR-style signature at offset 510 so the
#     kernel loop auto-mount picks 2048-byte ISO9660 blocks. Without it the
#     loop default of 512-byte blocks triggers `isofs_fill_super: bread failed,
#     iso_blknum=16, block=32` and mount fails with EINVAL.
#   - Casper additionally requires `ignore_uuid` (otherwise it reads its own
#     /conf/uuid.conf and demands a matching /.disk/casper-uuid* on the media)
#     and `layerfs-path=filesystem.squashfs` (otherwise it walks the layered
#     /conf/conf.d/default-layer.conf chain which our merged squashfs does
#     not provide). Those go in the iPXE script, not this build — see
#     ipxe-casper.example.ipxe.

: "${SQUASHFS_OUTPUT:?}"
: "${ISO_OUTPUT:?}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"

SQFS="$DIST/$SQUASHFS_OUTPUT"
ISO="$DIST/$ISO_OUTPUT"

if [ ! -s "$SQFS" ]; then
    echo "[05-iso] missing $SQFS — run 02-customize-rootfs first" >&2
    exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
    echo "[05-iso] xorriso not found in PATH" >&2
    exit 1
fi

echo "[05-iso] Building $ISO from $SQFS (graft at /casper/filesystem.squashfs)"
rm -f "$ISO"

# Volume label is alphanumeric only (xorriso warns on hyphens and complies with
# ISO 9660 / ECMA 119 rules).
xorriso -as mkisofs \
    -V "UBUNTU26PXE" \
    -J -joliet-long -r \
    -partition_offset 16 \
    -graft-points \
        "/casper/$SQUASHFS_OUTPUT=$SQFS" \
    -o "$ISO"

ls -lh "$ISO"
echo "[05-iso] Verifying ISO contents:"
xorriso -indev "$ISO" -find / 2>&1 | tail -5
echo "[05-iso] done"
