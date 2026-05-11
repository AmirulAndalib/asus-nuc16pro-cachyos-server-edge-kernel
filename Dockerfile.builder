FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Pacific/Auckland

RUN dpkg --add-architecture amd64 && \
    apt-get update && \
    apt-get full-upgrade -y && \
    apt-get install -y \
      git build-essential bc kmod cpio rsync xz-utils zstd tar wget curl \
      flex bison libncurses-dev libssl-dev libssl-dev:amd64 \
      libelf-dev libdw-dev elfutils dwarves pahole \
      debhelper devscripts fakeroot ca-certificates \
      clang lld llvm ccache python3 perl gawk gettext \
      libudev-dev libpci-dev lz4 bsdutils \
      file xxd pkg-config jq \
      gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu libc6-dev-amd64-cross && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
