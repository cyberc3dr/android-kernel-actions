#!/usr/bin/env bash

# --- Argument Validation ---
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "ERROR: Missing required arguments." 1>&2
    echo "Usage: $0 <arch> <defconfig> <image_name>" 1>&2
    echo "Example: $0 arm64 vendor/kona-perf_defconfig Image.gz" 1>&2
    exit 1
fi
# -------------------------

msg(){
    echo
    echo "==> $*"
    echo
}

err(){
    echo 1>&2
    echo "==> $*" 1>&2
    echo 1>&2
}

set_output(){
    echo "$1=$2" >> $GITHUB_OUTPUT
}

workdir="$GITHUB_WORKSPACE"
arch="$1"
defconfig="$2"
image="$3"
repo_name="${GITHUB_REPOSITORY/*\/}"
zipper_path="${ZIPPER_PATH:-zipper}"
kernel_path="${KERNEL_PATH:-.}"
name="${NAME:-$repo_name}"

# === FIX for Debian Jessie (8) Environment ===
msg "Configuring APT for Debian Jessie archive..."
cat <<EOF > /etc/apt/sources.list
deb http://archive.debian.org/debian/ jessie main non-free contrib
deb-src http://archive.debian.org/debian/ jessie main non-free contrib
deb http://archive.debian.org/debian-security/ jessie/updates main non-free contrib
deb-src http://archive.debian.org/debian-security/ jessie/updates main non-free contrib
EOF

msg "Updating container..."
apt-get update -y --force-yes

msg "Installing essential packages..."
# build-essential on Jessie provides GCC 4.9.
# The 'python' package provides Python 2.
apt-get install -y --force-yes build-essential git make bc bison \
    openssl curl zip kmod cpio flex libelf-dev libssl-dev wget \
    device-tree-compiler ca-certificates python xz-utils ccache
# =======================================================

set_output hash "$(cd "$kernel_path" && git rev-parse HEAD || exit 127)"

git submodule update --init

msg "Verifying host GCC version..."
gcc --version

msg "Installing cross-compiler toolchain..."
if [[ $arch = "arm64" ]]; then
    arch_opts="ARCH=${arch} SUBARCH=${arch}"
    export ARCH="$arch"
    export SUBARCH="$arch"

    toolchain_url="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/archive/refs/heads/lineage-18.1.tar.gz"
    toolchain_dest="/opt/lineage-gcc-arm64"
    toolchain_prefix="aarch64-linux-android-"

elif [[ $arch = "arm" ]]; then
    arch_opts="ARCH=${arch} SUBARCH=${arch}"
    export ARCH="$arch"
    export SUBARCH="$arch"

    toolchain_url="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9/archive/refs/heads/cm-14.1.tar.gz"
    toolchain_dest="/opt/lineage-gcc-arm"
    toolchain_prefix="arm-linux-androideabi-"

else
    err "Currently this action only supports arm and arm64, refer to the README for more detail"
    exit 100
fi

msg "Downloading GCC toolchain for ${arch}..."
echo "URL: $toolchain_url"
if ! wget --no-check-certificate "$toolchain_url" -O /tmp/lineage-gcc.tar.gz; then
    err "Failed downloading toolchain."
    exit 1
fi

mkdir -p "$toolchain_dest"
msg "Extracting toolchain to $toolchain_dest"
if ! tar xf /tmp/lineage-gcc.tar.gz -C "$toolchain_dest" --strip-components=1; then
    err "Failed to extract toolchain"
    exit 1
fi

msg "Setting toolchain permissions..."
chmod +x $toolchain_dest/bin/*

export PATH="$toolchain_dest/bin:$PATH"
export CROSS_COMPILE="$toolchain_prefix"

make_opts="CCACHE=ccache"
host_make_opts=""

cd "$workdir"/"$kernel_path" || exit 127
start_time="$(date +%s)"
date="$(date +%d%m%Y-%I%M)"
tag="$(git branch | sed 's/*\ //g')"
echo "branch/tag: $tag"
echo "make options:" $arch_opts $make_opts $host_make_opts
echo "CROSS_COMPILE: $CROSS_COMPILE"
command -v "${CROSS_COMPILE}gcc" || { err "Cross compiler not found in PATH"; exit 1; }
command -v gcc || { err "Host compiler (gcc) not found in PATH"; exit 1; }

mkdir -p out

msg "Generating defconfig from \`make $defconfig\`..."
if ! make O=out $arch_opts $make_opts $host_make_opts "$defconfig"; then
    err "Failed generating .config, make sure it is actually available in arch/${arch}/configs/ and is a valid defconfig file"
    exit 2
fi
msg "Begin building kernel..."

make O=out $arch_opts $make_opts $host_make_opts -j"$(nproc --all)" prepare

if ! make O=out $arch_opts $make_opts $host_make_opts -j"$(nproc --all)"; then
    err "Failed building kernel, probably the toolchain is not compatible with the kernel, or kernel source problem"
    exit 3
fi
set_output elapsed_time "$(echo "$(date +%s)"-"$start_time" | bc)"
msg "Packaging the kernel..."
zip_filename="${name}-${tag}-${date}.zip"
if [[ -e "$workdir"/"$zipper_path" ]]; then
    cp out/arch/"$arch"/boot/"$image" "$workdir"/"$zipper_path"/"$image"
    cd "$workdir"/"$zipper_path" || exit 127
    rm -rf .git
    zip -r9 "$zip_filename" . -x .gitignore README.md || exit 127
    set_output outfile "$workdir"/"$zipper_path"/"$zip_filename"
    cd "$workdir" || exit 127
    exit 0
else
    msg "No zip template provided, releasing the kernel image instead"
    set_output outfile out/arch/"$arch"/boot/"$image"
    exit 0
fi