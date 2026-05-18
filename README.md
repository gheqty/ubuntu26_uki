# ubuntu26_uki

Reproducible build of a **PXE-bootable Unified Kernel Image (UKI)** plus a matching
live **root filesystem** (squashfs) for Ubuntu 26.04 on `amd64`. The intended use is
to provision a bare-metal server over PXE so that it boots into a generic Ubuntu
26.04 environment, brings up the network via DHCP, starts `sshd`, and is then
configured remotely over SSH.

The build runs inside a pinned Ubuntu 26.04 container so that the host OS does
not influence the result. KVM is used for a local QEMU smoke-test before any
artifact leaves this directory.

## Produced artifacts

After `make all`, the `dist/` directory contains:

| File                       | What it is                                                                |
| -------------------------- | ------------------------------------------------------------------------- |
| `ubuntu-26.04-pxe.efi`     | UKI: kernel + dracut initrd (with `livenet`+`dmsquash-live`) + cmdline    |
| `filesystem.squashfs`      | Live root filesystem with `openssh-server` and `cloud-init`               |
| `SHA256SUMS`               | Checksums of the two artifacts above                                      |
| `README.md`                | Deploy notes for whoever runs PXE on the receiving end                    |

## Build

Requirements on the build host: `docker` (or `podman`), `make`, and — only for
the QEMU smoke-test — `qemu-system-x86_64`, KVM access (`/dev/kvm`), and an OVMF
firmware image.

```sh
# fetch ISO, customize rootfs, build initrd + UKI, write checksums:
make all

# run the artifacts in QEMU/KVM and verify SSH comes up on localhost:2222:
make test

# wipe work/ and dist/:
make clean
```

To re-target the live media URL without rebuilding the rootfs:

```sh
make uki LIVE_MEDIA_URL=https://example.invalid/path
```

## QEMU smoke-test

`make test` rebuilds the UKI with `LIVE_MEDIA_URL=http://10.0.2.2:${QEMU_HTTP_PORT}`
so QEMU's user-mode networking reaches a local HTTP server, then:

1. Serves `dist/filesystem.squashfs` over HTTP on the host.
2. Boots the UKI via OVMF (`qemu-system-x86_64 -bios OVMF.fd -kernel test.efi -enable-kvm`).
3. Waits for `sshd` to accept a public-key login on `localhost:${QEMU_SSH_PORT}`.
4. Runs `uname -a; cat /etc/os-release; df -h /; hostname` inside the guest.

Pass succeeds when the SSH command exits 0 and the guest reports
`Ubuntu 26.04 LTS` on the Ubuntu-shipped kernel
(currently `7.0.0-14-generic`) with `/` mounted on `LiveOS_rootfs`.

A passing run looks like:

```
[99-test] Booting via -kernel + OVMF (log: work/qemu/qemu.log)
[99-test] Waiting up to 300s for SSH on localhost:2222
[99-test] SSH login succeeded. Inspecting guest:
Linux ubuntu26-pxe 7.0.0-14-generic ... x86_64 GNU/Linux
PRETTY_NAME="Ubuntu 26.04 LTS"
Filesystem      Size  Used Avail Use% Mounted on
LiveOS_rootfs   2.3G  1.3G 1014M  57% /
ubuntu26-pxe
[99-test] PASS
```

The smoke-test requires `TEST_SSH_KEY` to point at a private key whose
public half is in `keys/authorized_keys`. To use an existing key from
`~/.ssh/`:

```sh
TEST_SSH_KEY=~/.ssh/id_ed25519 make test
```

## Customization

* `keys/authorized_keys` — public keys that get baked into `/root/.ssh/authorized_keys`.
  Add one key per line.
* `overlay/` — files that are copied into the rootfs verbatim (preserving mode and
  ownership of files placed there as root). Useful for `sshd_config.d/`, drop-in
  systemd units, `/etc/hostname`, etc.
* `cmdline.in` — kernel command line, with `${LIVE_MEDIA_URL}` substituted at
  build time.
* `VERSIONS` — pinned versions and defaults for ISO URL, ports, memory, etc.

## How the boot works

The UKI is loaded by the receiving PXE/UEFI bootloader. Its embedded initrd is
built with `dracut`, including the `livenet` and `dmsquash-live` modules. It
parses the kernel command line, brings up networking via DHCP, fetches the
squashfs over HTTP from `${LIVE_MEDIA_URL}/filesystem.squashfs`, copies it
into RAM (`rd.live.ram`), mounts it via an overlay, and `switch_root`s into
the Ubuntu rootfs. The rootfs runs entirely from RAM; reboots return to a
clean state.

For the deploy environment to work, `filesystem.squashfs` must be reachable
at `${LIVE_MEDIA_URL}/filesystem.squashfs` from the booting machine. If that
is not possible, the squashfs can be embedded as a second initrd (see the
`EMBED_SQUASHFS=1` branch in `scripts/04-build-uki.sh`).

## Layout

```
.
├── Makefile
├── VERSIONS
├── cmdline.in
├── build/
│   ├── Dockerfile
│   └── entrypoint.sh
├── scripts/
│   ├── 01-fetch.sh          # download ISO, extract kernel + squashfs layers
│   ├── 02-customize-rootfs.sh  # merge layers, add openssh-server, ssh keys, …
│   ├── 03-build-initrd.sh   # dracut initramfs for the Ubuntu kernel
│   ├── 04-build-uki.sh      # ukify kernel + initrd + cmdline → .efi
│   ├── 05-checksums.sh      # write dist/SHA256SUMS + dist/README.md
│   └── 99-test-qemu.sh      # QEMU/KVM smoke-test
├── overlay/
├── keys/
│   └── authorized_keys
├── work/         # intermediate; gitignored
└── dist/         # output; gitignored
```
