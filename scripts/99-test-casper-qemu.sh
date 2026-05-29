#!/bin/bash
# QEMU smoke-test for Path B (stock casper initrd boot, see README).
# Mirrors 99-test-qemu.sh but boots vmlinuz+initrd+ISO instead of a UKI.
set -euo pipefail

: "${ISO_OUTPUT:?}"
: "${QEMU_HTTP_PORT:=8080}"
: "${QEMU_SSH_PORT:=2222}"
: "${QEMU_MEMORY:=8G}"
: "${QEMU_SMP:=4}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO/work"
DIST="$REPO/dist"
CASPER="$WORK/casper"
TEST="$WORK/qemu-casper"

mkdir -p "$TEST/srv"

ISO="$DIST/$ISO_OUTPUT"
VMLINUZ="$CASPER/vmlinuz"
INITRD="$CASPER/initrd"

for f in "$ISO" "$VMLINUZ" "$INITRD"; do
    if [ ! -s "$f" ]; then
        echo "[99-test-casper] missing $f" >&2
        exit 1
    fi
done

# Casper expects vmlinuz/initrd/ISO at the same HTTP root. Stage symlinks so
# the python http.server only exposes those three files.
ln -sf "$ISO"     "$TEST/srv/$ISO_OUTPUT"
ln -sf "$VMLINUZ" "$TEST/srv/vmlinuz"
ln -sf "$INITRD"  "$TEST/srv/initrd"

echo "[99-test-casper] Starting HTTP server in $TEST/srv on :${QEMU_HTTP_PORT}"
( cd "$TEST/srv" && exec python3 -m http.server "$QEMU_HTTP_PORT" --bind 127.0.0.1 ) \
    >"$TEST/http.log" 2>&1 &
HTTP_PID=$!

# Mirrors ipxe-casper.example.ipxe; url= points at the QEMU user-net gateway
# (10.0.2.2 = host). `toram` from the example is dropped — copying the squashfs
# into RAM doubles guest memory pressure and isn't needed to validate the path.
CMDLINE="boot=casper ip=dhcp url=http://10.0.2.2:${QEMU_HTTP_PORT}/${ISO_OUTPUT} ignore_uuid layerfs-path=filesystem.squashfs console=ttyS0,115200n8 console=tty0"

QEMU_LOG="$TEST/qemu.log"
echo "[99-test-casper] Booting QEMU (log: $QEMU_LOG)"
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp "$QEMU_SMP" \
    -m "$QEMU_MEMORY" \
    -machine q35 \
    -netdev "user,id=net0,hostfwd=tcp::${QEMU_SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial mon:stdio \
    -kernel "$VMLINUZ" \
    -initrd "$INITRD" \
    -append "$CMDLINE" \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

cleanup() {
    set +e
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

echo "[99-test-casper] Waiting up to 480s for SSH on localhost:${QEMU_SSH_PORT}"
SSH_OK=0
for i in $(seq 1 96); do
    sleep 5
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[99-test-casper] QEMU exited early; tail of log:"
        tail -80 "$QEMU_LOG"
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
    echo "[99-test-casper] SSH did not come up; tail of QEMU log:"
    tail -120 "$QEMU_LOG"
    exit 1
fi

echo "[99-test-casper] SSH login succeeded. Inspecting guest:"
ssh -p "$QEMU_SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${TEST_SSH_KEY:+-i "$TEST_SSH_KEY"} \
    root@localhost 'uname -a; cat /etc/os-release | head -2; df -h /; mount | grep -E "casper|squash|cdrom"; hostname'

echo "[99-test-casper] PASS"
