#!/bin/sh
set -e

UBUNTU_DIR="/mnt/host/wsl/ubuntu"
mkdir -p "$UBUNTU_DIR"

if [ ! -f "$UBUNTU_DIR/bin/bash" ]; then
    echo "[1/4] Downloading ubuntu-base..."
    wget -q -O /mnt/host/wsl/ubuntu-base.tar.gz https://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.5-base-amd64.tar.gz
    tar -xzf /mnt/host/wsl/ubuntu-base.tar.gz -C "$UBUNTU_DIR"
    rm -f /mnt/host/wsl/ubuntu-base.tar.gz
fi

cp /etc/resolv.conf "$UBUNTU_DIR/etc/resolv.conf"
mountpoint -q "$UBUNTU_DIR/proc" || mount -t proc proc "$UBUNTU_DIR/proc"
mountpoint -q "$UBUNTU_DIR/sys" || mount -t sysfs sys "$UBUNTU_DIR/sys"
mountpoint -q "$UBUNTU_DIR/dev" || mount --bind /dev "$UBUNTU_DIR/dev"
mkdir -p "$UBUNTU_DIR/mnt/g" "$UBUNTU_DIR/mnt/c"
mountpoint -q "$UBUNTU_DIR/mnt/g" || mount --bind /mnt/host/g "$UBUNTU_DIR/mnt/g"
mountpoint -q "$UBUNTU_DIR/mnt/c" || mount --bind /mnt/host/c "$UBUNTU_DIR/mnt/c"

cat << 'EOF' > "$UBUNTU_DIR/root/inner_setup.sh"
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

if ! which make >/dev/null 2>&1; then
    echo "[2/4] Installing build-essential and kernel build deps..."
    apt-get update -qq
    apt-get install -y -qq build-essential bc kmod cpio xz-utils git wget curl ca-certificates python3 libncurses-dev libssl-dev bison flex libelf-dev
fi

mkdir -p /opt/arm-eabi-4.7 /opt/src

if [ ! -f /opt/arm-eabi-4.7/bin/arm-eabi-gcc ]; then
    echo "[3/4] Downloading AOSP arm-eabi-4.7 toolchain..."
    curl -sL https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-eabi-4.7/+archive/refs/heads/kitkat-release.tar.gz | tar -xz -C /opt/arm-eabi-4.7
fi

/opt/arm-eabi-4.7/bin/arm-eabi-gcc --version

if [ ! -d /opt/src/linux-3.18.24 ]; then
    echo "[4/4] Downloading linux-3.18.24.tar.xz..."
    wget -q -O /opt/src/linux-3.18.24.tar.xz https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.24.tar.xz
    tar -xJf /opt/src/linux-3.18.24.tar.xz -C /opt/src
    rm -f /opt/src/linux-3.18.24.tar.xz
fi

echo "=== BUILD_ENV_READY ==="
EOF

chmod +x "$UBUNTU_DIR/root/inner_setup.sh"
chroot "$UBUNTU_DIR" /root/inner_setup.sh
