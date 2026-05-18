#!/bin/bash
set -euo pipefail

cd /repo
set -a
. ./VERSIONS
set +a

case "${1:-all}" in
    all)
        ./scripts/01-fetch.sh
        ./scripts/02-customize-rootfs.sh
        ./scripts/03-build-initrd.sh
        ./scripts/04-build-uki.sh
        ./scripts/05-checksums.sh
        ;;
    fetch)
        ./scripts/01-fetch.sh
        ;;
    rootfs)
        ./scripts/02-customize-rootfs.sh
        ;;
    initrd)
        ./scripts/03-build-initrd.sh
        ;;
    uki)
        ./scripts/04-build-uki.sh
        ;;
    checksums)
        ./scripts/05-checksums.sh
        ;;
    test)
        ./scripts/99-test-qemu.sh
        ;;
    shell)
        exec /bin/bash
        ;;
    *)
        echo "usage: $0 {all|fetch|rootfs|initrd|uki|checksums|test|shell}" >&2
        exit 64
        ;;
esac
