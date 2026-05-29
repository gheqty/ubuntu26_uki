#!/bin/bash
set -euo pipefail

: "${UKI_OUTPUT:?}"
: "${SQUASHFS_OUTPUT:?}"
: "${LIVE_MEDIA_URL:?}"
: "${UBUNTU_VERSION:?}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"
CASPER="$REPO/work/casper"

cd "$DIST"

for f in "$UKI_OUTPUT" "$SQUASHFS_OUTPUT"; do
    if [ ! -s "$f" ]; then
        echo "[06-checksums] missing artifact: $f" >&2
        exit 1
    fi
done

# The casper-path artifacts are optional. Include them in the checksum file if
# 05-build-iso.sh has been run and the casper kernel/initrd are present.
EXTRA=()
[ -s "$DIST/${ISO_OUTPUT:-}" ] && EXTRA+=("$ISO_OUTPUT")
if [ -s "$CASPER/vmlinuz" ] && [ -s "$CASPER/initrd" ]; then
    cp -f "$CASPER/vmlinuz" "$DIST/vmlinuz"
    cp -f "$CASPER/initrd"  "$DIST/initrd"
    EXTRA+=("vmlinuz" "initrd")
fi

echo "[06-checksums] Writing SHA256SUMS"
sha256sum "$UKI_OUTPUT" "$SQUASHFS_OUTPUT" "${EXTRA[@]}" > SHA256SUMS
cat SHA256SUMS

echo "[06-checksums] Writing dist/README.md"
cat > README.md <<EOF
# Ubuntu ${UBUNTU_VERSION} PXE artifacts

This build supports **two deploy paths** that share the same
\`${SQUASHFS_OUTPUT}\` rootfs but differ in how the kernel reaches it.

## Path A — UKI (dracut, intended design)

| File | Purpose |
| ---- | ------- |
| \`${UKI_OUTPUT}\` | UKI: kernel + dracut initrd + cmdline as one EFI binary. Boot this over PXE/UEFI. |
| \`${SQUASHFS_OUTPUT}\` | Live root filesystem (squashfs). Must be reachable over HTTP at \`${LIVE_MEDIA_URL}/${SQUASHFS_OUTPUT}\`. |

The UKI was built with:

\`\`\`
LIVE_MEDIA_URL=${LIVE_MEDIA_URL}
\`\`\`

To change this URL, rebuild the UKI (the rootfs does not need to change):

\`\`\`sh
make uki LIVE_MEDIA_URL=https://example.invalid/path
\`\`\`

Deploy:

1. Make \`${SQUASHFS_OUTPUT}\` available over HTTP at \`${LIVE_MEDIA_URL}/${SQUASHFS_OUTPUT}\`.
2. Boot the target host's PXE/UEFI loader and chain into \`${UKI_OUTPUT}\`.
3. The UKI brings up the network via DHCP, downloads the squashfs into RAM
   (\`rd.live.ram\`), and boots into a live Ubuntu ${UBUNTU_VERSION} environment.
4. \`sshd\` is enabled at boot. Log in as \`root\` with a key from the build's
   \`keys/authorized_keys\` file.
5. The system runs entirely from RAM. A reboot returns it to a clean state.

## Path B — stock casper initrd + ISO

Some BMaaS environments cannot use the UKI directly and must chain a plain
iPXE script to the kernel and initrd. In that case use the casper artifacts:

| File | Purpose |
| ---- | ------- |
| \`vmlinuz\` | Ubuntu kernel from the upstream live ISO (copied verbatim). |
| \`initrd\` | Stock casper initrd from the upstream live ISO. |
| \`${ISO_OUTPUT:-ubuntu-26.04-pxe.iso}\` | ISO wrapper around \`${SQUASHFS_OUTPUT}\` placed at \`/casper/${SQUASHFS_OUTPUT}\`. Required by the casper initrd's \`do_urlmount\`. |
| \`${SQUASHFS_OUTPUT}\` | The same squashfs as Path A. |

The casper initrd refuses to mount a raw squashfs over HTTP and has two
defaults that need to be overridden on the kernel command line. See
\`ipxe-casper.example.ipxe\` at the repo root for the exact script.

## Verifying integrity

\`\`\`sh
sha256sum -c SHA256SUMS
\`\`\`
EOF

ls -lh "$DIST"
echo "[06-checksums] done"
