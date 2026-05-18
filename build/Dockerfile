FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl wget \
        xorriso \
        squashfs-tools \
        systemd-ukify \
        systemd-boot-efi \
        dracut \
        fakeroot \
        python3 python3-pefile \
        mtools dosfstools gdisk parted \
        gettext-base \
        coreutils gzip xz-utils zstd cpio \
        file rsync \
        qemu-system-x86 ovmf \
        openssh-client \
        sudo \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
ENTRYPOINT ["/repo/build/entrypoint.sh"]
