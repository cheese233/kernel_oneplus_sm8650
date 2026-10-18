#!/bin/bash
#
# build_ksu_sm8650.sh -- build BakaSU as a loadable kernel module (kernelsu.ko)
# for OnePlus SM8650 (OnePlus 12 waffle / 13R giulia / Ace 5 giuliac).
#
# Verified working on YAAP 17 (kernel 6.1.177-@84fa7a31): flash the resulting
# kernelsu.ko through ksud/ksupatcher into init_boot (kernel left untouched).
#
# Non-obvious requirements, learned the hard way:
#   * Build IN-TREE. With O=<dir> the module Kbuild include paths
#     (-I$(KBUILD_EXTMOD)) resolve inside the objtree and headers are not found.
#   * KCFLAGS must tolerate this tree warnings: clang 21 does not know
#     -Werror=alloc-size and CONFIG_WERROR promotes warnings to errors.
#   * After switching KSU from y to m, include/generated/autoconf.h has to be
#     re-synced, otherwise CONFIG_KSU_TRACEPOINT_HOOK is missing and core/init.c
#     fails with "Unsupported hook type".
#   * scripts/mod/modpost.c needs check_exports() removed for out-of-tree
#     modules, and it carries a stray empty
#     if (fnmatch("*kernelsu", mod->name, 0)) in write_mod_c_file() that breaks
#     .mod.c generation for modules named *kernelsu.

echo -e "\n[INFO]: BUILD STARTED FOR BakaSU LKM..!\n"

export KBUILD_BUILD_USER="@realahnet"

KSU_REPO="https://github.com/Baka-SU/BakaSU"
KSU_DIR="KernelSU"

install_dependencies() {
    echo -e "\n[INFO]: Detecting OS and installing dependencies...\n"

    if command -v dnf &> /dev/null; then
        echo -e "[INFO]: Fedora/RHEL-based system detected, using dnf...\n"
        sudo dnf group install "c-development" "development-tools" && \
        sudo dnf install -y dtc lz4 xz zlib-devel java-latest-openjdk-devel python3 \
            p7zip p7zip-plugins android-tools erofs-utils \
            ncurses-devel libX11-devel readline-devel mesa-libGL-devel python3-markdown \
            libxml2 libxslt dos2unix kmod openssl elfutils-libelf-devel dwarves \
            openssl-devel libarchive zstd rsync openssl-devel-engine --skip-unavailable

    elif command -v apt &> /dev/null; then
        echo -e "[INFO]: Ubuntu/Debian-based system detected, using apt...\n"
        sudo apt update && sudo apt install -y git device-tree-compiler lz4 xz-utils zlib1g-dev openjdk-17-jdk gcc g++ python3 python-is-python3 p7zip-full android-sdk-libsparse-utils erofs-utils \
            default-jdk git gnupg flex bison gperf build-essential zip curl libc6-dev libncurses-dev libx11-dev libreadline-dev libgl1 libgl1-mesa-dev \
            python3 make sudo gcc g++ bc grep tofrodos python3-markdown libxml2-utils xsltproc zlib1g-dev python-is-python3 libc6-dev libtinfo6 \
            make repo cpio kmod openssl libelf-dev pahole libssl-dev libarchive-tools zstd rsync --fix-missing && wget http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb && sudo dpkg -i libtinfo5_6.3-2ubuntu0.1_amd64.deb

    else
        echo -e "[ERROR]: Neither dnf nor apt package manager found. Please install dependencies manually.\n"
    fi

    # Clone clang (same toolchain the shipped modules were built with)
    git clone --depth=1 https://github.com/realahnet/clang-r563880c toolchains/clang

    touch .requirements
}

if [ ! -f ".requirements" ]; then
    install_dependencies
fi

export BUILD_OPTIONS=(
    ARCH=arm64
    LLVM=toolchains/clang/bin/clang
    KCFLAGS="-Wno-unknown-warning-option -Wno-error"
)

# ld.lld / llvm-ar from the bundled toolchain must be visible to kconfig checks
export PATH="$(pwd)/toolchains/clang/bin:$PATH"

prepare_bakasu() {
    rm -rf "$KSU_DIR"
    git clone --depth=1 "$KSU_REPO" "$KSU_DIR"

    # BakaSU Kbuild insists on a real git checkout, so link the repo in
    ln -sfn "../$KSU_DIR/kernel" drivers/kernelsu

    grep -q "kernelsu" drivers/Makefile || echo "obj-$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || \
        sed -i 's|^endmenu|source "drivers/kernelsu/Kconfig"\nendmenu|' drivers/Kconfig

    python3 - <<'PY'
import re
p = "scripts/mod/modpost.c"
s = open(p).read()
if "check_exports" in s:
    key = "static void check_exports(struct module *mod)"
    i = s.find(key)
    if i >= 0:
        j = s.find("{", i)
        depth, k = 0, j
        while k < len(s):
            if s[k] == "{":
                depth += 1
            elif s[k] == "}":
                depth -= 1
                if depth == 0:
                    k += 1
                    break
            k += 1
        s = s[:i] + s[k:]
    s = s.replace("\tcheck_exports(mod);\n", "")
    s = s.replace("check_exports(mod);", "")
old = '\tif (fnmatch("*kernelsu", mod->name, 0))\n\t\n\tadd_header(&buf, mod);'
if old in s:
    s = s.replace(old, "\tadd_header(&buf, mod);")
open(p, "w").write(s)
PY

    sed -i '/config KSU/,/help/{s/default y/default m/}' drivers/kernelsu/Kconfig
}

build_mod() {
    prepare_bakasu

    make "${BUILD_OPTIONS[@]}" -j"$(nproc --all)" \
        gki_defconfig vendor/pineapple_GKI.config vendor/oplus/pineapple_GKI.config || exit 1

    scripts/config --file .config -m KSU -d DEBUG_INFO_BTF -d DEBUG_INFO_BTF_MODULES

    make "${BUILD_OPTIONS[@]}" olddefconfig || exit 1
    make "${BUILD_OPTIONS[@]}" syncconfig || exit 1

    make "${BUILD_OPTIONS[@]}" -j"$(nproc --all)" prepare modules_prepare || exit 1
    make "${BUILD_OPTIONS[@]}" -j"$(nproc --all)" security/ || exit 1
    make "${BUILD_OPTIONS[@]}" -j"$(nproc --all)" M=drivers/kernelsu modules || exit 1

    ./toolchains/clang/bin/llvm-objcopy --strip-debug drivers/kernelsu/kernelsu.ko ./kernelsu.ko

    rm -rf "$KSU_DIR" drivers/kernelsu
    git restore drivers/Makefile drivers/Kconfig scripts/ 2>/dev/null || true

    echo -e "\n[INFO]: BUILD FINISHED..! -> ./kernelsu.ko\n"
    echo "[INFO]: undefined symbols: $(./toolchains/clang/bin/llvm-nm -u kernelsu.ko | wc -l)"
    echo "[INFO]: $(strings -a kernelsu.ko | grep -m1 '^vermagic=')"
}

build_mod
