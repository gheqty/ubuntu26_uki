#!/bin/bash
set -euo pipefail

: "${UKI_OUTPUT:?}"
: "${LIVE_MEDIA_URL:?}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO/work"
CASPER="$WORK/casper"
INITRD_DIR="$WORK/initrd"
DIST="$REPO/dist"

mkdir -p "$DIST" "$WORK"

KERNEL="$CASPER/vmlinuz"
INITRD="$INITRD_DIR/initramfs.img"

for f in "$KERNEL" "$INITRD"; do
    if [ ! -s "$f" ]; then
        echo "[04-uki] missing $f — run earlier steps first" >&2
        exit 1
    fi
done

CMDLINE_FILE="$WORK/cmdline"
echo "[04-uki] Rendering cmdline with LIVE_MEDIA_URL=$LIVE_MEDIA_URL"
envsubst < "$REPO/cmdline.in" | tr -d '\n' > "$CMDLINE_FILE"
echo >> "$CMDLINE_FILE"
echo "[04-uki] cmdline = $(cat "$CMDLINE_FILE")"

UKI_OUT="$DIST/$UKI_OUTPUT"

if ! command -v ukify >/dev/null 2>&1; then
    echo "[04-uki] ukify not found in PATH — install systemd-ukify" >&2
    exit 1
fi

echo "[04-uki] Building UKI"
rm -f "$UKI_OUT"

UKI_ARGS=(
    build
    --linux="$KERNEL"
    --initrd="$INITRD"
    --cmdline=@"$CMDLINE_FILE"
    --output="$UKI_OUT"
)

# If a second initrd with the squashfs embedded is desired (offline UKI), set
# EMBED_SQUASHFS=1 in the environment. The cmdline must then be adjusted to
# tell dracut to use a local image rather than a remote URL.
if [ "${EMBED_SQUASHFS:-0}" = "1" ]; then
    SQFS="$DIST/${SQUASHFS_OUTPUT:?}"
    if [ ! -s "$SQFS" ]; then
        echo "[04-uki] EMBED_SQUASHFS=1 but $SQFS missing" >&2
        exit 1
    fi
    UKI_ARGS+=(--initrd="$SQFS")
fi

ukify "${UKI_ARGS[@]}"

ls -lh "$UKI_OUT"
echo "[04-uki] PE sections:"
if command -v objdump >/dev/null 2>&1; then
    objdump -h "$UKI_OUT" | grep -E '\.(linux|initrd|cmdline|osrel|uname|dtb|sbat)' || true
fi
echo "[04-uki] done"
