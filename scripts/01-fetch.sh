#!/bin/bash
set -euo pipefail

: "${ISO_FILENAME:?}"
: "${ISO_URL:?}"
: "${ISO_SHA256_URL:?}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$REPO/downloads"
WORK="$REPO/work"
CASPER="$WORK/casper"

mkdir -p "$DOWNLOADS" "$CASPER"

ISO_PATH="$DOWNLOADS/$ISO_FILENAME"

if [ -f "$ISO_PATH" ]; then
    echo "[01-fetch] ISO already present: $ISO_PATH"
else
    echo "[01-fetch] Downloading $ISO_URL"
    curl -fL --retry 3 -o "$ISO_PATH.partial" "$ISO_URL"
    mv "$ISO_PATH.partial" "$ISO_PATH"
fi

echo "[01-fetch] Verifying SHA256"
SUMS=$(curl -fsSL "$ISO_SHA256_URL")
EXPECTED=$(printf '%s\n' "$SUMS" | awk -v f="*$ISO_FILENAME" '$2==f {print $1}')
if [ -z "$EXPECTED" ]; then
    EXPECTED=$(printf '%s\n' "$SUMS" | awk -v f="$ISO_FILENAME" '$2==f {print $1}')
fi
if [ -z "$EXPECTED" ]; then
    echo "[01-fetch] WARNING: $ISO_FILENAME not found in SHA256SUMS; skipping verification" >&2
else
    ACTUAL=$(sha256sum "$ISO_PATH" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "[01-fetch] SHA256 mismatch: expected $EXPECTED got $ACTUAL" >&2
        exit 1
    fi
    echo "[01-fetch] SHA256 OK: $ACTUAL"
fi

echo "[01-fetch] Extracting casper/ from ISO"
rm -rf "$CASPER"
mkdir -p "$CASPER"
xorriso -osirrox on \
        -indev "$ISO_PATH" \
        -extract /casper "$CASPER" \
        2>&1 | tail -5

echo "[01-fetch] Files in $CASPER:"
ls -lh "$CASPER" | head -30

# Ubuntu 26.04 live-server uses layered squashfs:
#   ubuntu-server-minimal.squashfs                — base layer
#   ubuntu-server-minimal.ubuntu-server.squashfs  — server layer (merged on top)
#   ubuntu-server-minimal.ubuntu-server.installer.squashfs  — subiquity, not used
# We require the kernel, the casper initrd, and both server layers.
for f in vmlinuz initrd \
         ubuntu-server-minimal.squashfs \
         ubuntu-server-minimal.ubuntu-server.squashfs; do
    if [ ! -s "$CASPER/$f" ]; then
        echo "[01-fetch] missing or empty: $CASPER/$f" >&2
        exit 1
    fi
done

echo "[01-fetch] done"
