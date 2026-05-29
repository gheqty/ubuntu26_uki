SHELL := /bin/bash

REPO := $(CURDIR)

include VERSIONS
export

# Native build runs the scripts directly on the host. Tools required:
#   ukify, xorriso, unsquashfs, mksquashfs, mkfs.vfat, mformat, mcopy,
#   envsubst, rsync, curl, python3, qemu-system-x86_64, OVMF
# On Arch:   pacman -S systemd-ukify xorriso squashfs-tools mtools \
#                     dosfstools rsync gettext qemu-system-x86 edk2-ovmf
# On Ubuntu: apt install systemd-ukify xorriso squashfs-tools mtools \
#                       dosfstools rsync gettext-base curl python3 \
#                       qemu-system-x86 ovmf

DOCKER ?= docker
IMAGE  := ubuntu26-uki-build:local

DOCKER_RUN := $(DOCKER) run --rm -it \
    --privileged \
    --device /dev/kvm \
    -v $(REPO):/repo \
    -w /repo \
    $(IMAGE)

.PHONY: all fetch rootfs initrd uki iso checksums test clean distclean \
        docker-all docker-build docker-shell help

help:
	@echo "Native targets (run scripts directly, require local tools):"
	@echo "  all          - fetch + rootfs + initrd + uki + iso + checksums"
	@echo "  fetch        - download ISO, extract casper/"
	@echo "  rootfs       - customize and rebuild filesystem.squashfs"
	@echo "  initrd       - build the dracut initramfs"
	@echo "  uki          - build the UKI .efi (Path A — dracut)"
	@echo "  iso          - wrap squashfs in ISO for casper deploy (Path B)"
	@echo "  checksums    - write dist/SHA256SUMS and dist/README.md"
	@echo "  test         - QEMU/KVM smoke-test"
	@echo "  clean        - remove work/ and dist/"
	@echo "  distclean    - also remove downloads/"
	@echo ""
	@echo "Containerized targets (reproducible, require docker/podman):"
	@echo "  docker-build - build the build-container image"
	@echo "  docker-all   - run 'all' inside the build-container"
	@echo "  docker-shell - open a shell inside the build-container"

all: fetch rootfs initrd uki iso checksums

fetch:
	./scripts/01-fetch.sh

rootfs:
	./scripts/02-customize-rootfs.sh

initrd:
	./scripts/03-build-initrd.sh

uki:
	./scripts/04-build-uki.sh

iso:
	./scripts/05-build-iso.sh

checksums:
	./scripts/06-checksums.sh

test:
	./scripts/99-test-qemu.sh

docker-build:
	$(DOCKER) build -t $(IMAGE) build/

docker-all: docker-build
	$(DOCKER_RUN) all

docker-shell: docker-build
	$(DOCKER_RUN) shell

clean:
	rm -rf work/ dist/

distclean: clean
	rm -rf downloads/
