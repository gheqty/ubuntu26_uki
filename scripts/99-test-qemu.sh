#!/bin/bash
set -euo pipefail

: "${UKI_OUTPUT:?}"
: "${SQUASHFS_OUTPUT:?}"
: "${QEMU_HTTP_PORT:=8080}"
: "${QEMU_SSH_PORT:=2222}"
: "${QEMU_MEMORY:=8G}"
: "${QEMU_SMP:=4}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO/work"
DIST="$REPO/dist"
TEST="$WORK/qemu"

mkdir -p "$TEST"

SQFS="$DIST/$SQUASHFS_OUTPUT"
UKI="$DIST/$UKI_OUTPUT"

for f in "$SQFS" "$UKI"; do
    if [ ! -s "$f" ]; then
        echo "[99-test] missing $f" >&2
        exit 1
    fi
done

# QEMU user-net puts the host at 10.0.2.2. Rebuild a dedicated test UKI with a
# cmdline pointing at the host's HTTP port so the guest can fetch the squashfs.
echo "[99-test] Building test UKI with LIVE_MEDIA_URL=http://10.0.2.2:${QEMU_HTTP_PORT}"
TEST_UKI="$TEST/test.efi"
LIVE_MEDIA_URL="http://10.0.2.2:${QEMU_HTTP_PORT}" \
UKI_OUTPUT="qemu-test.efi" \
SQUASHFS_OUTPUT="$SQUASHFS_OUTPUT" \
    bash "$REPO/scripts/04-build-uki.sh"
mv "$DIST/qemu-test.efi" "$TEST_UKI"

echo "[99-test] Starting HTTP server in $DIST on :${QEMU_HTTP_PORT}"
( cd "$DIST" && exec python3 -m http.server "$QEMU_HTTP_PORT" --bind 0.0.0.0 ) \
    >"$TEST/http.log" 2>&1 &
HTTP_PID=$!

# Two test modes:
#   direct  — QEMU loads the UKI via -kernel (PE/EFI stub path, fastest)
#   ovmf    — Boot via OVMF firmware + GPT-wrapped ESP. Closer to real PXE/UEFI.
# Default: direct. Set TEST_MODE=ovmf to switch.
TEST_MODE="${TEST_MODE:-direct}"

QEMU_LOG="$TEST/qemu.log"
QEMU_BASE=(
    -enable-kvm
    -cpu host
    -smp "$QEMU_SMP"
    -m "$QEMU_MEMORY"
    -machine q35
    -netdev "user,id=net0,hostfwd=tcp::${QEMU_SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0
    -nographic
    -serial mon:stdio
)

if [ "$TEST_MODE" = "direct" ]; then
    # QEMU's SeaBIOS won't load a PE/EFI binary via -kernel, but OVMF (which
    # supports LoadImage on PE32+) does. We provide OVMF as -bios and pass the
    # UKI as -kernel. This is the fastest "is this UKI bootable" smoke-test
    # and still exercises the EFI stub + initrd + cmdline path.
    OVMF_FW=""
    for c in \
        /usr/share/edk2/x64/OVMF.4m.fd \
        /usr/share/OVMF/OVMF.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2-ovmf/x64/OVMF.fd \
    ; do [ -f "$c" ] && OVMF_FW="$c" && break; done
    if [ -z "$OVMF_FW" ]; then
        echo "[99-test] OVMF firmware not found; install ovmf/edk2-ovmf" >&2
        kill $HTTP_PID 2>/dev/null || true
        exit 1
    fi
    echo "[99-test] Booting via -kernel + OVMF (log: $QEMU_LOG)"
    qemu-system-x86_64 "${QEMU_BASE[@]}" \
        -bios "$OVMF_FW" \
        -kernel "$TEST_UKI" \
        >"$QEMU_LOG" 2>&1 &
else
    echo "[99-test] Preparing ESP+GPT disk for OVMF boot"
    ESP_FAT="$TEST/esp.fat"
    DISK="$TEST/disk.img"
    rm -f "$ESP_FAT" "$DISK"
    truncate -s 512M "$ESP_FAT"
    mkfs.vfat -F 32 -n EFIBOOT "$ESP_FAT" >/dev/null
    mmd -i "$ESP_FAT" ::/EFI ::/EFI/BOOT
    mcopy -i "$ESP_FAT" "$TEST_UKI" ::/EFI/BOOT/BOOTX64.EFI

    DISK_SIZE_MB=560
    truncate -s "${DISK_SIZE_MB}M" "$DISK"
    sgdisk --clear \
           --new=1:2048:+510M \
           --typecode=1:EF00 \
           --change-name=1:EFISYS \
           "$DISK" >/dev/null
    dd if="$ESP_FAT" of="$DISK" bs=1M seek=1 conv=notrunc status=none

    OVMF_CODE=""
    OVMF_VARS=""
    for c in \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
    ; do [ -f "$c" ] && OVMF_CODE="$c" && break; done
    for v in \
        /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
    ; do [ -f "$v" ] && OVMF_VARS="$v" && break; done

    if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS" ]; then
        echo "[99-test] OVMF firmware not found" >&2
        kill $HTTP_PID 2>/dev/null || true
        exit 1
    fi

    VARS_RW="$TEST/OVMF_VARS.fd"
    cp "$OVMF_VARS" "$VARS_RW"

    echo "[99-test] Booting via OVMF (log: $QEMU_LOG)"
    qemu-system-x86_64 "${QEMU_BASE[@]}" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$VARS_RW" \
        -drive if=none,id=esp,format=raw,file="$DISK" \
        -device virtio-blk-pci,drive=esp,bootindex=1 \
        >"$QEMU_LOG" 2>&1 &
fi
QEMU_PID=$!

cleanup() {
    set +e
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

echo "[99-test] Waiting up to 300s for SSH on localhost:${QEMU_SSH_PORT}"
SSH_OK=0
for i in $(seq 1 60); do
    sleep 5
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[99-test] QEMU exited early; tail of log:"
        tail -40 "$QEMU_LOG"
        exit 1
    fi
    if ssh -p "$QEMU_SSH_PORT" \
           -o ConnectTimeout=3 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes \
           -o PreferredAuthentications=publickey \
           ${TEST_SSH_KEY:+-i "$TEST_SSH_KEY"} \
           root@localhost true 2>/dev/null; then
        SSH_OK=1
        break
    fi
done

if [ "$SSH_OK" != "1" ]; then
    echo "[99-test] SSH did not come up; tail of QEMU log:"
    tail -80 "$QEMU_LOG"
    exit 1
fi

echo "[99-test] SSH login succeeded. Inspecting guest:"
ssh -p "$QEMU_SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${TEST_SSH_KEY:+-i "$TEST_SSH_KEY"} \
    root@localhost 'uname -a; cat /etc/os-release | head -2; df -h /; hostname'

echo "[99-test] PASS"
