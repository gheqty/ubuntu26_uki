#!/bin/bash
set -euo pipefail

: "${UKI_OUTPUT:?}"
: "${SQUASHFS_OUTPUT:?}"
: "${LIVE_MEDIA_URL:?}"
: "${UBUNTU_VERSION:?}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"

cd "$DIST"

for f in "$UKI_OUTPUT" "$SQUASHFS_OUTPUT"; do
    if [ ! -s "$f" ]; then
        echo "[04-checksums] missing artifact: $f" >&2
        exit 1
    fi
done

echo "[04-checksums] Writing SHA256SUMS"
sha256sum "$UKI_OUTPUT" "$SQUASHFS_OUTPUT" > SHA256SUMS
cat SHA256SUMS

echo "[04-checksums] Writing dist/README.md"
cat > README.md <<EOF
# Ubuntu ${UBUNTU_VERSION} PXE artifacts

| File | Purpose |
| ---- | ------- |
| \`${UKI_OUTPUT}\` | Unified Kernel Image (UKI): kernel + initrd + cmdline as one EFI binary. Boot this over PXE/UEFI. |
| \`${SQUASHFS_OUTPUT}\` | Live root filesystem (squashfs). Must be reachable over HTTP at the URL embedded in the UKI cmdline. |
| \`SHA256SUMS\` | Checksums for the two artifacts above. |

## Embedded boot URL

The UKI was built with:

\`\`\`
LIVE_MEDIA_URL=${LIVE_MEDIA_URL}
\`\`\`

The kernel command line therefore points at:

\`\`\`
${LIVE_MEDIA_URL}/${SQUASHFS_OUTPUT}
\`\`\`

To change this URL, rebuild the UKI (the rootfs does not need to change):

\`\`\`sh
make uki LIVE_MEDIA_URL=https://example.invalid/path
\`\`\`

## How to deploy

1. Make \`${SQUASHFS_OUTPUT}\` available over HTTP at \`${LIVE_MEDIA_URL}/${SQUASHFS_OUTPUT}\`.
2. Boot the target host's PXE/UEFI loader and chain into \`${UKI_OUTPUT}\`.
3. The UKI brings up the network via DHCP, downloads the squashfs into RAM
   (\`rd.live.ram\`), and boots into a live Ubuntu ${UBUNTU_VERSION} environment.
4. \`sshd\` is enabled at boot. Log in as \`root\` using a key from the build's
   \`keys/authorized_keys\` file (or via cloud-init user data, if the booting
   environment provides one).
5. The system runs entirely from RAM. A reboot returns it to a clean state.

## Verifying integrity

\`\`\`sh
sha256sum -c SHA256SUMS
\`\`\`
EOF

ls -lh "$DIST"
echo "[04-checksums] done"
