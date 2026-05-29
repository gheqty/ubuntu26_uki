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
| `ubuntu-26.04-pxe.iso`     | ISO wrapper around the squashfs, for the casper-initrd deploy path        |
| `vmlinuz`, `initrd`        | Upstream Ubuntu kernel + stock casper initrd, copied verbatim             |
| `filesystem.squashfs`      | Live root filesystem with `openssh-server` and `cloud-init`               |
| `SHA256SUMS`               | Checksums of the artifacts above                                          |
| `README.md`                | Deploy notes for whoever runs PXE on the receiving end                    |

The build supports two deploy paths that share the same `filesystem.squashfs`:

- **Path A — UKI (dracut)**: a self-contained `ubuntu-26.04-pxe.efi` whose
  embedded dracut initrd pulls `filesystem.squashfs` directly over HTTP. This
  is the intended design — see the existing sections below.
- **Path B — stock casper initrd**: for environments that can't chain into a
  UKI and instead serve `vmlinuz`, `initrd`, and `ubuntu-26.04-pxe.iso`
  separately via an iPXE script. See [Alternative deploy path: stock casper
  initrd](#alternative-deploy-path-stock-casper-initrd) below.

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

## End-to-end PXE test

The smoke-test above loads the UKI directly via `-kernel`. To verify the
real PXE chain the deploy environment will use, point QEMU at an
OVMF-backed firmware with a network boot order and let QEMU's built-in
DHCP+TFTP server hand out the UKI:

```sh
# build a test UKI pointing the squashfs URL at the host
set -a ; . ./VERSIONS ; set +a
LIVE_MEDIA_URL="http://10.0.2.2:8080" UKI_OUTPUT="qemu-test.efi" \
    bash scripts/04-build-uki.sh

mkdir -p work/pxe/tftp
cp dist/qemu-test.efi work/pxe/tftp/BOOTX64.EFI
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd work/pxe/OVMF_VARS.fd

# serve the squashfs over HTTP
( cd dist && python3 -m http.server 8080 ) &

# UEFI PXE boot: TFTP fetches BOOTX64.EFI, the UKI then fetches the squashfs
qemu-system-x86_64 \
    -enable-kvm -cpu host -m 4G -smp 4 -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file=work/pxe/OVMF_VARS.fd \
    -netdev user,id=net0,tftp=work/pxe/tftp,bootfile=BOOTX64.EFI,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0,romfile= \
    -boot order=n \
    -nographic -serial mon:stdio
```

A passing run shows the UEFI PXE client doing DHCPv4, fetching the UKI via
TFTP, then dracut fetching the squashfs over HTTP:

```
>>Start PXE over IPv4.
  NBP filename is BOOTX64.EFI
BdsDxe: starting Boot0002 "UEFI PXEv4 (MAC:525400123456)" …
…
[ ... ] Copying live image to RAM...
127.0.0.1 - - [..] "GET /filesystem.squashfs HTTP/1.1" 200 -
…
Linux ubuntu26-pxe 7.0.0-14-generic … Ubuntu 26.04 LTS
```

After ~30 s the guest is reachable on `ssh -p 2222 root@localhost`. This
exercises exactly the path the deploy environment uses: DHCP option 67 →
TFTP UKI fetch → UEFI `LoadImage` → EFI stub → kernel + dracut → HTTP
squashfs → systemd → sshd.

## Alternative deploy path: stock casper initrd

Some PXE/BMaaS environments cannot chain into the UKI directly and instead
expect a plain iPXE script that fetches the kernel and initrd separately.
In that case the dracut initramfs built by `03-build-initrd.sh` is unused;
the deployer serves the upstream Ubuntu **casper** initrd from
`work/casper/initrd` and the squashfs from inside a wrapper ISO.

`make all` already produces everything needed for this path:

| Artifact                  | Built by                  |
| ------------------------- | ------------------------- |
| `dist/vmlinuz`            | `scripts/06-checksums.sh` copies from `work/casper/vmlinuz` |
| `dist/initrd`             | `scripts/06-checksums.sh` copies from `work/casper/initrd`  |
| `dist/ubuntu-26.04-pxe.iso` | `scripts/05-build-iso.sh` wraps `filesystem.squashfs` at `/casper/filesystem.squashfs` with `xorriso -partition_offset 16` |

Serve those four files (plus `filesystem.squashfs` if you want it cached
separately) over HTTP and point your iPXE script at them. A working template
lives at the repo root in [`ipxe-casper.example.ipxe`](./ipxe-casper.example.ipxe).
The kernel command line must include four casper-specific tokens, each
addressing a specific upstream casper behavior:

| Token                              | What it fixes                                                                                                                                                                                                                                            |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `url=<...>.iso`                    | Casper's `do_urlmount` only honors `url=` when the value ends in `.iso`. It then `wget`s the URL, loop-mounts the result, and expects `/casper/*.squashfs` inside. A raw `url=*.squashfs` is silently dropped by the parser.                              |
| `ignore_uuid`                      | The initrd ships `/conf/uuid.conf` (a built-in UUID); without `ignore_uuid`, `matches_uuid` looks for a matching `/.disk/casper-uuid*` on the media. Our minimal ISO doesn't carry one, so the mount is rolled back with no error and casper panics.    |
| `layerfs-path=filesystem.squashfs` | The initrd's `/conf/conf.d/default-layer.conf` defaults `LAYERFS_PATH` to the layered `ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs` chain. We collapsed those layers into one file in step 02, so we override the path.               |
| (implicit) `-partition_offset 16`  | Not a kernel arg — a build-time `xorriso` flag (see `scripts/05-build-iso.sh`). Without it the ISO has no MBR signature, and the kernel's auto-loop chooses 512-byte logical blocks; the iso9660 driver then fails `bread` at block 32 (offset 32 KiB). |

End-to-end the sequence on the booted host is:

```
iPXE → fetch vmlinuz + initrd (HTTP) → kernel + casper initrd starts
       → casper wgets ubuntu-26.04-pxe.iso into RAM
       → mount -o ro ubuntu-26.04-pxe.iso /cdrom   (iso9660 + Joliet + RRIP)
       → is_casper_path /cdrom  passes (sees /cdrom/casper/filesystem.squashfs)
       → matches_uuid /cdrom    passes (UUID was cleared by ignore_uuid)
       → layered overlay mounts /cdrom/casper/filesystem.squashfs as lower layer
       → switch_root into the squashfs
       → systemd brings up ssh.service → sshd listens on :22
```

### Deploy helper: `scripts/bmaas.sh`

When the target is a [CoreWeave BMaaS](https://docs.coreweave.com/) node, you
will need to trigger reboots, query node state, and pick the right machine
out of a pool while iterating on the boot chain.
[`scripts/bmaas.sh`](./scripts/bmaas.sh) is a thin bash wrapper around the
CoreWeave bare-metal API that covers those needs without pulling in a heavier
SDK. Source it for an interactive session, or invoke it as a CLI:

```sh
export CW_TOKEN="$(...)"        # bearer token from https://console.coreweave.com/tokens
export CW_ZONE="us-west-09b"    # zone the node lives in

# inspect
./scripts/bmaas.sh overview               # pools + nodes table for the zone
./scripts/bmaas.sh summary-nodes <pool>   # compact list of nodes in a pool
./scripts/bmaas.sh get-node <node-id>     # full JSON for one node

# kick a deploy
./scripts/bmaas.sh reboot-node <node-id>          # power-cycle only
./scripts/bmaas.sh reconfigure-node <node-id>     # DPU reconfigure + reboot
                                                  # (use after NodeProfile changes)
```

The script has no hard-coded secrets and reads only `CW_TOKEN` / `CW_ZONE`
(and optionally `CW_ORG`) from the environment. `set -euo pipefail` is on,
and the `BASH_SOURCE` guard at the bottom is `:-`-defaulted so it can be
sourced safely from zsh as well as bash.

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
│   ├── 03-build-initrd.sh   # dracut initramfs for the Ubuntu kernel (Path A)
│   ├── 04-build-uki.sh      # ukify kernel + initrd + cmdline → .efi  (Path A)
│   ├── 05-build-iso.sh      # wrap squashfs into a casper-mountable ISO (Path B)
│   ├── 06-checksums.sh      # write dist/SHA256SUMS + dist/README.md
│   ├── 99-test-qemu.sh      # QEMU/KVM smoke-test
│   └── bmaas.sh             # CoreWeave BMaaS CLI helper (deploy-time, not build)
├── ipxe-casper.example.ipxe # iPXE script template for Path B
├── overlay/
├── keys/
│   └── authorized_keys
├── work/         # intermediate; gitignored
└── dist/         # output; gitignored
```
