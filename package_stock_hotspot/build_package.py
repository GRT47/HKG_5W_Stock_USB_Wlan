#!/usr/bin/env python3
"""
Builds the standalone NEMESIS package 'stock.hotspot' and USB installation bundle:
  - g:\\github\\HKG_headunit_syanal\\package_stock_hotspot\\usb_root\\packages\\stock.hotspot.zip
  - g:\\github\\HKG_headunit_syanal\\HKG_5W_Stock_Hotspot.zip

Key features:
1. Distinguishes built-in Wi-Fi vehicles (e.g., Niro EV with Broadcom SDIO mmc1:0001)
   from USB Wi-Fi vehicles (e.g., EV6, Ioniq 5, K8 HEV without SDIO mmc1:0001).
2. On EV6 / Wi-Fi-less Gen5W vehicles:
   - Loads a tiny [permanent] no-op 'bcmdhd' kernel module stub (bcmdhd_stub.ko /
     bcmdhd_stub_tcc897x.ko) so libhardware_legacy.so is_wifi_driver_loaded() returns 1
     immediately without ever invoking /system/wifi/bcmdhd.ko (which fails with -ENODEV
     after SDIO/GPIO retries and blocks/crashes system_server).
   - Pre-loads Realtek USB Wi-Fi drivers (RTL88x2BU / RTL8851BU) at boot as 'wlan0'
     with in-driver AOA blocking (dev.devt |= 0x00080000U) and standard UDP 67/68 DHCP
     passthrough so the 100% stock Kia/Hyundai Hotspot Settings UI (HKMC_WifiSettings)
     and CarrotBridge control Hotspot natively.
"""
import os
import shutil
import struct
import zipfile

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE_DIR = os.path.dirname(BASE_DIR)
SRC_MODULES_DIR = r"g:\github\HKG_headunit_usbwifi\package_usbwifi_hotspot\modules"
KALLSYMS_ROOT = r"g:\github\HKG_headunit_usbwifi\log\usbwifi_kernel_dump"

DST_MODULES_DIR = os.path.join(BASE_DIR, "modules")
PKG_SRC_DIR = os.path.join(BASE_DIR, "pkg_src")
USB_ROOT_DIR = os.path.join(BASE_DIR, "usb_root")
OUTER_ZIP_PATH = os.path.join(WORKSPACE_DIR, "HKG_5W_Stock_Hotspot.zip")

# ---------------------------------------------------------------------------
# 1. Patch & Verify Kernel Modules (.ko) for Stock Hotspot (wlan0 + UDP 67)
#    + Build [permanent] no-op bcmdhd_stub.ko for libhardware_legacy.so
# ---------------------------------------------------------------------------
KO_PATCH_SPECS = {
    "8851bu.ko": {
        "ifname_offset": 0x3443A8,
        "code_patches": [
            # rtw_ethtool_get_drvinfo: return 0 immediately (bx lr) to prevent
            # NULL pointer dereference on wiphy->dev.parent (+0xc0) when
            # /system/bin/wl ('wl country KR') sends SIOCETHTOOL (ETHTOOL_GDRVINFO) to wlan0
            (0x003E90, 0xE1A0C00D, 0xE12FFF1E),
            # rtw_xmit_entry: bypass UDP 1067 -> 67 TX port translation
            (0x00A0C4, 0x1A000037, 0xEA000037),
            # rtw_os_recv_indicate_pkt: bypass UDP 67 -> 1067 RX port translation
            (0x00ABD4, 0x1A00002E, 0xEA00002E),
        ],
    },
    "8851bu_tcc897x.ko": {
        "ifname_offset": 0x331D80,
        "code_patches": [
            # rtw_ethtool_get_drvinfo: return 0 immediately (bx lr) to prevent
            # NULL pointer dereference on wiphy->dev.parent (+0xc0) when
            # /system/bin/wl ('wl country KR') sends SIOCETHTOOL (ETHTOOL_GDRVINFO) to wlan0
            (0x003D28, 0xE1A0C00D, 0xE12FFF1E),
            # rtw_xmit_entry: bypass UDP 1067 -> 67 TX port translation
            (0x009D80, 0x1A000037, 0xEA000037),
            # rtw_os_recv_indicate_pkt: bypass UDP 67 -> 1067 RX port translation
            (0x00A7E0, 0x1A00002E, 0xEA00002E),
        ],
    },
    "88x2bu.ko": {
        "ifname_offset": 0x13FA58,
        "code_patches": [
            # rtw_os_recv_indicate_pkt: bypass UDP 67 -> 1067 RX port translation
            (0x06CC08, 0x0A000026, 0xE1A00000),
            (0x06CCD0, 0x1AFFFFCD, 0xEAFFFFCD),
            # _rtw_xmit_entry: bypass UDP 1067 -> 67 TX port translation
            (0x06BE94, 0x0A000044, 0xEA000044),
            (0x06BEDC, 0x1A000032, 0xEA000032),
        ],
    },
    "88x2bu_tcc897x.ko": {
        "ifname_offset": 0x136C94,
        "code_patches": [
            # rtw_os_recv_indicate_pkt: bypass UDP 67 -> 1067 RX port translation
            (0x0685CC, 0x0A000026, 0xE1A00000),
            (0x068694, 0x1AFFFFCD, 0xEAFFFFCD),
            # _rtw_xmit_entry: bypass UDP 1067 -> 67 TX port translation
            (0x0678FC, 0x0A000044, 0xEA000044),
            (0x067944, 0x1A000032, 0xEA000032),
        ],
    },
}

BCMDHD_STUB_SPECS = {
    "bcmdhd_stub.ko": os.path.join(
        KALLSYMS_ROOT, "usbwifi_kernel_dump_ev6", "modules", "extra_ko", "dup_ttyd.ko"
    ),
    "bcmdhd_stub_tcc897x.ko": os.path.join(
        KALLSYMS_ROOT,
        "usbwifi_kernel_dump_niroev",
        "modules",
        "extra_ko",
        "dup_ttyd.ko",
    ),
}


def build_bcmdhd_stub_ko(src_dup_ttyd_path, dst_path, ko_name):
    """
    Creates a [permanent] no-op kernel module named 'bcmdhd' from dup_ttyd.ko:
      1. Patches .gnu.linkonce.this_module + 12 (56-byte module name) to 'bcmdhd\\0...'.
      2. Replaces init_module at .init.text + 0 with 'mov r0, #0; bx lr'
         (00 00 a0 e3 1e ff 2f e1).
      3. Disables .rel.init.text (sets sh_type=SHT_NULL, sh_size=0) so no relocations
         modify .init.text.
      4. Preserves the single relocation in .rel.gnu.linkonce.this_module at +0xc0
         (init_module) with NO cleanup_module relocation so the kernel marks 'bcmdhd'
         as [permanent] in /proc/modules (preventing wifi_unload_driver() delete_module
         from unloading it when Hotspot is toggled OFF).
    """
    with open(src_dup_ttyd_path, "rb") as f:
        buf = bytearray(f.read())

    if buf[:4] != b"\x7fELF":
        raise RuntimeError(f"{ko_name}: invalid ELF magic in {src_dup_ttyd_path}")

    e_shoff = struct.unpack_from("<I", buf, 32)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", buf, 46)

    def get_shdr(idx):
        return struct.unpack_from("<10I", buf, e_shoff + idx * e_shentsize)

    shstr_off, shstr_size = get_shdr(e_shstrndx)[4], get_shdr(e_shstrndx)[5]
    shstr = bytes(buf[shstr_off : shstr_off + shstr_size])

    def get_sname(off):
        return shstr[off : shstr.find(b"\x00", off)].decode("ascii", "ignore")

    found_init = False
    found_rel_init = False
    found_this_mod = False

    for i in range(e_shnum):
        sh_pos = e_shoff + i * e_shentsize
        h = get_shdr(i)
        nm = get_sname(h[0])
        if nm == ".init.text":
            init_off = h[4]
            # mov r0, #0; bx lr (ARMv7 little-endian)
            buf[init_off : init_off + 8] = bytes(
                [0x00, 0x00, 0xA0, 0xE3, 0x1E, 0xFF, 0x2F, 0xE1]
            )
            found_init = True
        elif nm == ".rel.init.text":
            # Set sh_type (offset +4) = 0 (SHT_NULL) and sh_size (offset +20) = 0
            struct.pack_into("<I", buf, sh_pos + 4, 0)
            struct.pack_into("<I", buf, sh_pos + 20, 0)
            found_rel_init = True
        elif nm == ".gnu.linkonce.this_module":
            tm_off, tm_size = h[4], h[5]
            if tm_size != 0x154:
                raise RuntimeError(
                    f"{ko_name}: unexpected .gnu.linkonce.this_module size 0x{tm_size:x}"
                )
            buf[tm_off + 12 : tm_off + 12 + 56] = b"bcmdhd".ljust(56, b"\x00")
            found_this_mod = True

    if not (found_init and found_rel_init and found_this_mod):
        raise RuntimeError(f"{ko_name}: failed to locate required ELF sections")

    with open(dst_path, "wb") as f:
        f.write(buf)

    verify_ko_elf(dst_path, ko_name)


def build_and_verify_ko_modules():
    os.makedirs(DST_MODULES_DIR, exist_ok=True)
    for ko_name, spec in KO_PATCH_SPECS.items():
        src_path = os.path.join(SRC_MODULES_DIR, ko_name)
        dst_path = os.path.join(DST_MODULES_DIR, ko_name)
        in_path = src_path if os.path.exists(src_path) else dst_path
        with open(in_path, "rb") as f:
            buf = bytearray(f.read())

        # 1. Patch default ifname "rtwlan%d\0" -> "wlan%d\0\0\0"
        if_off = spec["ifname_offset"]
        cur_if = bytes(buf[if_off : if_off + 9])
        if cur_if == b"rtwlan%d\x00":
            buf[if_off : if_off + 9] = b"wlan%d\x00\x00\x00"
        elif cur_if != b"wlan%d\x00\x00\x00":
            raise RuntimeError(
                f"{ko_name}: unexpected bytes at ifname_offset 0x{if_off:x}: {cur_if!r}"
            )

        # Ensure no remaining "rtwlan%d" string exists in the binary
        if b"rtwlan%d" in buf:
            raise RuntimeError(f"{ko_name}: residual 'rtwlan%d' found in binary!")

        # 2. Patch in-driver DHCP port 67 <-> 1067 translation & rtw_ethtool_get_drvinfo guard
        for off, orig_insn, patched_insn in spec["code_patches"]:
            cur_insn = struct.unpack_from("<I", buf, off)[0]
            if cur_insn == orig_insn:
                struct.pack_into("<I", buf, off, patched_insn)
            elif cur_insn != patched_insn:
                raise RuntimeError(
                    f"{ko_name}: unexpected instruction at 0x{off:x}: "
                    f"0x{cur_insn:08x} (expected 0x{orig_insn:08x})"
                )

        with open(dst_path, "wb") as f:
            f.write(buf)

        # 3. Verify ELF header, .gnu.linkonce.this_module size (0x154), vermagic, and kallsyms
        verify_ko_elf(dst_path, ko_name)

    for stub_name, src_dup_path in BCMDHD_STUB_SPECS.items():
        dst_stub_path = os.path.join(DST_MODULES_DIR, stub_name)
        in_stub_path = src_dup_path if os.path.exists(src_dup_path) else dst_stub_path
        build_bcmdhd_stub_ko(in_stub_path, dst_stub_path, stub_name)


def verify_ko_elf(ko_path, ko_name):
    with open(ko_path, "rb") as f:
        data = f.read()

    if data[:4] != b"\x7fELF":
        raise RuntimeError(f"{ko_name}: invalid ELF magic")

    e_shoff = struct.unpack_from("<I", data, 32)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 46)

    def get_shdr(idx):
        return struct.unpack_from("<10I", data, e_shoff + idx * e_shentsize)

    shstr_off, shstr_size = get_shdr(e_shstrndx)[4], get_shdr(e_shstrndx)[5]
    shstr = data[shstr_off : shstr_off + shstr_size]

    def get_sname(off):
        return shstr[off : shstr.find(b"\x00", off)].decode("ascii", "ignore")

    this_mod_size = None
    undef_syms = []
    for i in range(e_shnum):
        h = get_shdr(i)
        nm = get_sname(h[0])
        if nm == ".gnu.linkonce.this_module":
            this_mod_size = h[5]
        elif nm == ".symtab":
            sym_off, sym_size, sym_link = h[4], h[5], h[6]
            str_off, str_size = get_shdr(sym_link)[4], get_shdr(sym_link)[5]
            strtab = data[str_off : str_off + str_size]
            for j in range(1, sym_size // 16):
                st_name, st_val, st_size, st_info, st_other, st_shndx = (
                    struct.unpack_from("<IIIBBH", data, sym_off + j * 16)
                )
                if st_shndx == 0:
                    sname = strtab[st_name : strtab.find(b"\x00", st_name)].decode(
                        "ascii", "ignore"
                    )
                    if sname:
                        undef_syms.append(sname)

    if this_mod_size != 0x154:
        raise RuntimeError(
            f"{ko_name}: .gnu.linkonce.this_module size is 0x{this_mod_size:x}, expected 0x154"
        )

    vm_idx = data.find(b"vermagic=")
    vermagic = data[vm_idx : data.find(b"\x00", vm_idx)].decode("ascii", "ignore")

    target_vehicles = (
        ["usbwifi_kernel_dump_niroev"]
        if "tcc897x" in ko_name
        else [
            "usbwifi_kernel_dump_ev6",
            "usbwifi_kernel_dump_ioniq5",
            "usbwifi_kernel_dump_k8hev",
        ]
    )
    for vdir in target_vehicles:
        ks_path = os.path.join(KALLSYMS_ROOT, vdir, "kernel", "kallsyms.txt")
        if os.path.exists(ks_path):
            with open(ks_path, "r", encoding="utf-8", errors="ignore") as kf:
                ks_syms = {line.split()[2] for line in kf if len(line.split()) >= 3}
            missing = [s for s in undef_syms if s not in ks_syms]
            if missing:
                raise RuntimeError(
                    f"{ko_name}: missing symbols in {vdir}: {missing[:10]}"
                )

    print(
        f"  [OK] {ko_name:24s}: size={len(data):,} bytes, this_module=0x{this_mod_size:x}, "
        f"{vermagic.strip()}, undef_syms={len(undef_syms)} (100% matched)"
    )


# ---------------------------------------------------------------------------
# 2. NEMESIS Package Descriptors & Scripts (pure Android 4.4 mksh compatible)
# ---------------------------------------------------------------------------
PKG_META = (
    "[nemesis]\n"
    "version=1.2\n"
    "id=stock.hotspot\n"
    "name=Stock WiFi Hotspot Enabler\n"
    "types=application,service\n"
    "postinstall=scripts/post.sh\n"
    "preuninstall=scripts/preun.sh\n"
    "\n"
    "[app.0]\n"
    "kind=sh\n"
    "path=bin/launch.sh\n"
    "uid=root\n"
    "\n"
    "[service.0]\n"
    "name=stock-hotspot\n"
    "kind=sh\n"
    "path=svc/stock-hotspot-daemon.sh\n"
    "uid=root\n"
    "mode=background\n"
)

USB_META = (
    "[nemesis]\n"
    "version=1.0\n"
    "type=install\n"
    "path=packages/stock.hotspot.zip\n"
)

POST_SH = r"""#!/system/bin/sh
export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib
export ANDROID_ROOT=/system
export ANDROID_DATA=/data

if [ -d "/data/nemesis/apps/stock.hotspot" ]; then
    APP_DIR="/data/nemesis/apps/stock.hotspot"
else
    APP_DIR="/data/nemesis/packages/stock.hotspot"
fi
TMP_DIR="/data/local/tmp/stock_hotspot"
mkdir -p "$TMP_DIR" 2>/dev/null
chmod 777 /data/local /data/local/tmp "$TMP_DIR" 2>/dev/null
chmod 755 "$APP_DIR/bin/launch.sh" "$APP_DIR/svc/stock-hotspot-daemon.sh" 2>/dev/null
chmod 644 "$APP_DIR/modules/"*.ko 2>/dev/null

# Set stock Hotspot properties immediately
setprop wifi.hotspot.subscription true
setprop wifi.hotspot.apn Public
setprop wifi.hotspot.internet 1

# 1. Stop any existing stock-hotspot-daemon instance so NEMESIS service manager
#    (sub_08620 right after postinstall) starts a clean single daemon instance.
if [ -f "$TMP_DIR/daemon.pid" ]; then
    read -r _dpid < "$TMP_DIR/daemon.pid" 2>/dev/null
    [ -n "$_dpid" ] && kill "$_dpid" 2>/dev/null
    rm -f "$TMP_DIR/daemon.pid" 2>/dev/null
fi
for _p in /proc/[0-9]*; do
    _p="${_p#/proc/}"
    [ "$_p" = "$$" ] && continue
    [ "$_p" = "$PPID" ] && continue
    _fd1="$(readlink "/proc/$_p/fd/1" 2>/dev/null)"
    case "$_fd1" in
        *stock_hotspot/daemon_stdout.log*)
            kill "$_p" 2>/dev/null
            ;;
    esac
done

exit 0
"""

PREUN_SH = r"""#!/system/bin/sh
export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin

TMP_DIR="/data/local/tmp/stock_hotspot"
if [ -f "$TMP_DIR/daemon.pid" ]; then
    read -r _dpid < "$TMP_DIR/daemon.pid" 2>/dev/null
    [ -n "$_dpid" ] && kill "$_dpid" 2>/dev/null
    rm -f "$TMP_DIR/daemon.pid" 2>/dev/null
fi
for _p in /proc/[0-9]*; do
    _p="${_p#/proc/}"
    [ "$_p" = "$$" ] && continue
    _fd1="$(readlink "/proc/$_p/fd/1" 2>/dev/null)"
    case "$_fd1" in
        *stock_hotspot/*) kill "$_p" 2>/dev/null ;;
    esac
done

if [ ! -e /sys/bus/mmc/devices/mmc1:0001 ]; then
    service call wifi 29 i32 0 i32 0 >/dev/null 2>&1
    ndc softap stopap >/dev/null 2>&1
    ip link set wlan0 down 2>/dev/null
    ip link set p2p0 down 2>/dev/null
    rmmod 88x2bu 2>/dev/null
    rmmod 8851bu 2>/dev/null
fi

rm -rf "$TMP_DIR" 2>/dev/null
exit 0
"""

LAUNCH_SH = r"""#!/system/bin/sh
export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib
export ANDROID_ROOT=/system
export ANDROID_DATA=/data

if [ -d "/data/nemesis/apps/stock.hotspot" ]; then
    APP_DIR="/data/nemesis/apps/stock.hotspot"
else
    APP_DIR="/data/nemesis/packages/stock.hotspot"
fi
TMP_DIR="/data/local/tmp/stock_hotspot"
mkdir -p "$TMP_DIR" 2>/dev/null
chmod 777 "$TMP_DIR" 2>/dev/null

# Ensure stock Hotspot subscription & public APN properties are active
setprop wifi.hotspot.subscription true
setprop wifi.hotspot.apn Public
setprop wifi.hotspot.internet 1

svc_alive=0
if [ -f "$TMP_DIR/daemon.pid" ]; then
    read -r _dpid < "$TMP_DIR/daemon.pid" 2>/dev/null
    if [ -n "$_dpid" ] && [ -d "/proc/$_dpid" ] && kill -0 "$_dpid" 2>/dev/null; then
        svc_alive=1
    fi
fi
if [ "$svc_alive" = "0" ]; then
    /system/bin/sh "$APP_DIR/svc/stock-hotspot-daemon.sh" </dev/null >>"$TMP_DIR/daemon_stdout.log" 2>&1 &
fi

# Open Kia/Hyundai Stock Wi-Fi Hotspot Settings UI directly.
# NOTE: Do NOT broadcast com.hkmc.intent.action.HOTSPOT_SHORTCUT here because
# HotspotService immediately invokes setWifiApEnabled(null, true) concurrently.
am start -n com.hkmc.wifisettings/.settings.ui.NetworkConnectionSettings >/dev/null 2>&1 || \
am start -a android.settings.WIFI_HOTSPOT_SETTINGS >/dev/null 2>&1
exit 0
"""

DAEMON_SH = r"""#!/system/bin/sh
# ==============================================================================
# Stock Wi-Fi Hotspot Daemon for Kia/Hyundai Gen5W (EV6 / Niro / Ioniq 5 / K8)
# ==============================================================================
export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib
export ANDROID_ROOT=/system
export ANDROID_DATA=/data

if [ -d "/data/nemesis/apps/stock.hotspot" ]; then
    APP_DIR="/data/nemesis/apps/stock.hotspot"
else
    APP_DIR="/data/nemesis/packages/stock.hotspot"
fi
MOD_DIR="$APP_DIR/modules"
TMP_DIR="/data/local/tmp/stock_hotspot"
LOG_FILE="$TMP_DIR/daemon.log"

mkdir -p "$TMP_DIR" 2>/dev/null
chmod 777 /data/local /data/local/tmp "$TMP_DIR" 2>/dev/null

# Single-instance guard (pure mksh)
if [ -f "$TMP_DIR/daemon.pid" ]; then
    read -r _old_dpid < "$TMP_DIR/daemon.pid" 2>/dev/null
    if [ -n "$_old_dpid" ] && [ "$_old_dpid" != "$$" ] && [ -d "/proc/$_old_dpid" ] && kill -0 "$_old_dpid" 2>/dev/null; then
        _old_fd1="$(readlink "/proc/$_old_dpid/fd/1" 2>/dev/null)"
        case "$_old_fd1" in
            *stock_hotspot/daemon_stdout.log*) exit 0 ;;
        esac
    fi
fi
for _p in /proc/[0-9]*; do
    _p="${_p#/proc/}"
    [ "$_p" = "$$" ] && continue
    [ "$_p" = "$PPID" ] && continue
    _p_fd1="$(readlink "/proc/$_p/fd/1" 2>/dev/null)"
    case "$_p_fd1" in
        *stock_hotspot/daemon_stdout.log*)
            if kill -0 "$_p" 2>/dev/null; then
                exit 0
            fi
            ;;
    esac
done

exec >>"$TMP_DIR/daemon_stdout.log" 2>&1
echo "$$" > "$TMP_DIR/daemon.pid" 2>/dev/null

log_msg() {
    echo "[stock.hotspot] $*"
    log -t StockHotspot "$*" 2>/dev/null
    echo "$(date) $*" >> "$LOG_FILE" 2>/dev/null
}

log_msg "=== Stock Wi-Fi Hotspot Daemon v1.2 started (pid=$$) ==="

# ------------------------------------------------------------------------------
# 1. Detect SoC Platform (tcc803x vs tcc897x) & Built-in SDIO Wi-Fi vs USB Wi-Fi
# ------------------------------------------------------------------------------
PLAT="$(getprop ro.board.platform 2>/dev/null)"
if [ -z "$PLAT" ]; then
    if grep -qi "tcc803" /proc/cpuinfo /proc/cmdline 2>/dev/null; then
        PLAT="tcc803x"
    else
        PLAT="tcc897x"
    fi
fi

if [ "$PLAT" = "tcc897x" ] && [ -f "$MOD_DIR/88x2bu_tcc897x.ko" ]; then
    KO_88X2BU="$MOD_DIR/88x2bu_tcc897x.ko"
    KO_8851BU="$MOD_DIR/8851bu_tcc897x.ko"
    KO_BCMDHD_STUB="$MOD_DIR/bcmdhd_stub_tcc897x.ko"
else
    KO_88X2BU="$MOD_DIR/88x2bu.ko"
    KO_8851BU="$MOD_DIR/8851bu.ko"
    KO_BCMDHD_STUB="$MOD_DIR/bcmdhd_stub.ko"
fi

if [ -e /sys/bus/mmc/devices/mmc1:0001 ] || [ -e /sys/bus/sdio/devices/mmc1:0001:1 ] || [ "$(getprop ro.carrier 2>/dev/null)" = "wifi-only" ]; then
    HAS_BUILTIN_WIFI=1
    log_msg "Platform=$PLAT: Detected built-in Broadcom SDIO Wi-Fi (mmc1:0001 / wifi-only). Using built-in wlan0."
else
    HAS_BUILTIN_WIFI=0
    log_msg "Platform=$PLAT: No built-in SDIO Wi-Fi on mmc1 (EV6 / USB Wi-Fi vehicle). Using USB Wi-Fi as wlan0."
fi

# ------------------------------------------------------------------------------
# 2. Ensure Stock Hotspot Prerequisite Files & Properties
# ------------------------------------------------------------------------------
prepare_stock_hotspot_env() {
    local _wf _wmac _cur_mac
    # Unlock Kia/Hyundai Stock Hotspot UI (HKMC_WifiSettings) & Public APN upstream
    setprop wifi.hotspot.subscription true
    setprop wifi.hotspot.apn Public
    setprop wifi.hotspot.internet 1
    if [ "$(getprop persist.sys.usbwifi.hotspot 2>/dev/null)" = "1" ]; then
        setprop persist.sys.usbwifi.hotspot 0
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

    # Ensure /data/misc/wifi, hostapd control socket dir, and symlinks exist
    # (EV6 lacks /data/misc/wifi/hostapd by default, which causes netd/hostapd to fail!)
    mkdir -p /data/misc/wifi /data/misc/wifi/hostapd /data/misc/wifi/sockets /data/misc/wifi/wpa_supplicant 2>/dev/null
    chown 1010:1010 /data/misc/wifi /data/misc/wifi/hostapd /data/misc/wifi/sockets /data/misc/wifi/wpa_supplicant 2>/dev/null
    chmod 0775 /data/misc/wifi 2>/dev/null
    chmod 0770 /data/misc/wifi/hostapd /data/misc/wifi/sockets /data/misc/wifi/wpa_supplicant 2>/dev/null

    # On UNECE security vehicles (EV6), WifiApConfigStore stores softap.conf and
    # taSecureStorageKeyFileId.sec inside /securedata/wifi/
    if [ -d /securedata ]; then
        mkdir -p /securedata/wifi 2>/dev/null
        chown 1000:1010 /securedata/wifi 2>/dev/null
        chmod 0775 /securedata/wifi 2>/dev/null
        [ -f /securedata/wifi/softap.conf ] && chown 1000:1010 /securedata/wifi/softap.conf 2>/dev/null
        [ -f /securedata/wifi/taSecureStorageKeyFileId.sec ] && chown 1000:1010 /securedata/wifi/taSecureStorageKeyFileId.sec 2>/dev/null
    fi

    if [ ! -e /data/misc/wifi/bcmdhd.cal ] && [ -f /system/wifi/bcmdhd.cal ]; then
        ln -s /system/wifi/bcmdhd.cal /data/misc/wifi/bcmdhd.cal 2>/dev/null
    fi
    if [ ! -e /data/misc/wifi/fw_bcmdhd.bin ] && [ -f /system/wifi/fw_bcmdhd.bin ]; then
        ln -s /system/wifi/fw_bcmdhd.bin /data/misc/wifi/fw_bcmdhd.bin 2>/dev/null
    fi
    if [ ! -e /data/misc/wifi/fw_bcmdhd_mfg.bin ] && [ -f /system/wifi/fw_bcmdhd_mfg.bin ]; then
        ln -s /system/wifi/fw_bcmdhd_mfg.bin /data/misc/wifi/fw_bcmdhd_mfg.bin 2>/dev/null
    fi

    if [ ! -f /data/misc/wifi/all_sta.list ]; then
        touch /data/misc/wifi/all_sta.list 2>/dev/null
    fi
    if [ ! -f /data/misc/wifi/entropy.bin ]; then
        dd if=/dev/urandom of=/data/misc/wifi/entropy.bin bs=21 count=1 >/dev/null 2>&1
    fi
    if [ ! -f /data/misc/wifi/firmware_path ]; then
        echo -n "/data/misc/wifi/fw_bcmdhd.bin" > /data/misc/wifi/firmware_path 2>/dev/null
    fi

    [ -f /data/misc/wifi/softap.conf ] && chown 1000:1000 /data/misc/wifi/softap.conf 2>/dev/null
    [ -f /data/misc/wifi/firmware_path ] && chown 0:0 /data/misc/wifi/firmware_path 2>/dev/null
    chmod 0660 /data/misc/wifi/firmware_path 2>/dev/null
    for _wf in all_sta.list entropy.bin hostapd.conf wpa_supplicant.conf wpa_supplicant_crc32.conf; do
        if [ -f "/data/misc/wifi/$_wf" ]; then
            chown 1000:1010 "/data/misc/wifi/$_wf" 2>/dev/null
            chmod 0660 "/data/misc/wifi/$_wf" 2>/dev/null
        fi
    done

    # Populate wifi.info.macaddress from wlan0 so libhardware_legacy.so wifi_load_driver()
    # does not attempt to read /sys/module/bcmdhd/parameters/mac_address_read on EV6
    if [ -f /sys/class/net/wlan0/address ]; then
        read -r _wmac < /sys/class/net/wlan0/address 2>/dev/null
        if [ -n "$_wmac" ] && [ "$_wmac" != "00:00:00:00:00:00" ]; then
            _cur_mac="$(getprop wifi.info.macaddress 2>/dev/null)"
            if [ "$_cur_mac" != "$_wmac" ]; then
                setprop wifi.info.macaddress "$_wmac"
            fi
        fi
    fi

    # Ensure dnsmasq lease files exist with permissions readable by system_server and dnsmasq
    mkdir -p /data/misc/dnsmasq /data/misc/dhcp 2>/dev/null
    chown 1000:1010 /data/misc/dnsmasq /data/misc/dhcp 2>/dev/null
    chmod 0775 /data/misc/dnsmasq /data/misc/dhcp 2>/dev/null
    touch /data/misc/dnsmasq/dnsmasq.leases /data/misc/dhcp/dnsmasq.leases 2>/dev/null
    chown 1000:1010 /data/misc/dnsmasq/dnsmasq.leases /data/misc/dhcp/dnsmasq.leases 2>/dev/null
    chmod 0666 /data/misc/dnsmasq/dnsmasq.leases /data/misc/dhcp/dnsmasq.leases 2>/dev/null

    # Clear eth0 192.168.0.123/24 if present so it never conflicts with
    # stock Android SoftAP subnet 192.168.0.1/24 on wlan0
    if ip addr show dev eth0 2>/dev/null | grep -q "192.168.0."; then
        ip addr flush dev eth0 2>/dev/null
        ip link set eth0 down 2>/dev/null
        log_msg "Cleared conflicting 192.168.0.x address from eth0"
    fi
}

# ------------------------------------------------------------------------------
# 3. Pre-load USB Wi-Fi Modules FIRST, Then Load [permanent] bcmdhd_stub.ko LAST
# ------------------------------------------------------------------------------
# CRITICAL ORDERING REQUIREMENT:
#   libhardware_legacy.so is_wifi_driver_loaded() (0x2868) checks:
#     1) getprop("wlan.driver.status") == "ok"
#     2) fgets(line, 65, "/proc/modules") WITHOUT A LOOP (only reads Line 1!)
#        and compares strncmp(line, "bcmdhd", 6) == 0.
#   Therefore, 88x2bu.ko and 8851bu.ko MUST be loaded FIRST, and bcmdhd_stub.ko
#   MUST be loaded AFTER them so "bcmdhd" stays at Line 1 of /proc/modules!
#   Furthermore, because bcmdhd_stub.ko is [permanent], wifi_unload_driver()
#   delete_module("bcmdhd") returns -EBUSY when Hotspot is turned OFF, keeping
#   "bcmdhd" at Line 1 of /proc/modules permanently!
sync_bcmdhd_driver_status() {
    local _drv_status
    if [ -e /sys/bus/mmc/devices/mmc1:0001 ] || [ -e /sys/bus/sdio/devices/mmc1:0001:1 ] || [ "$(getprop ro.carrier 2>/dev/null)" = "wifi-only" ]; then
        HAS_BUILTIN_WIFI=1
        return 0
    fi
    [ "$HAS_BUILTIN_WIFI" = "1" ] && return 0

    if ! grep -q "^bcmdhd " /proc/modules 2>/dev/null; then
        if [ -f "$KO_BCMDHD_STUB" ]; then
            insmod "$KO_BCMDHD_STUB" >>"$TMP_DIR/insmod.log" 2>&1
            if grep -q "^bcmdhd " /proc/modules 2>/dev/null; then
                log_msg "Loaded [permanent] ${KO_BCMDHD_STUB##*/} at top of /proc/modules"
            else
                log_msg "WARN: Failed to load ${KO_BCMDHD_STUB##*/}"
            fi
        fi
    fi

    # Keep wlan.driver.status=ok while USB Wi-Fi wlan0 is present (even after
    # wifi_unload_driver() sets it to "unloading" or "unloaded" when Hotspot is turned OFF)
    if [ -d /sys/class/net/wlan0 ]; then
        _drv_status="$(getprop wlan.driver.status 2>/dev/null)"
        if [ "$_drv_status" != "ok" ]; then
            setprop wlan.driver.status ok
            log_msg "Set wlan.driver.status=ok (was '$_drv_status')"
        fi
    fi
}

trigger_usb_modeswitch() {
    local _d _v _p _if_dir _if_id _scsi
    for _d in /sys/bus/usb/devices/*; do
        if [ -f "$_d/idVendor" ] && [ -f "$_d/idProduct" ]; then
            read -r _v < "$_d/idVendor" 2>/dev/null
            read -r _p < "$_d/idProduct" 2>/dev/null
            if [ "$_v" = "0bda" ] && [ "$_p" = "1a2b" ]; then
                log_msg "Detected Realtek 0bda:1a2b Virtual CD-ROM at ${_d##*/} -> triggering USB modeswitch"
                for _scsi in /dev/block/sr* /dev/sr* /dev/sg*; do
                    [ -e "$_scsi" ] && eject "$_scsi" 2>/dev/null
                done
                for _if_dir in "$_d/"*:*; do
                    [ -d "$_if_dir" ] || continue
                    _if_id="${_if_dir##*/}"
                    if [ -e "/sys/bus/usb/drivers/usb-storage/$_if_id" ]; then
                        echo "$_if_id" > /sys/bus/usb/drivers/usb-storage/unbind 2>/dev/null
                    fi
                    if [ -d /sys/bus/usb/drivers/rtl8851bu ]; then
                        echo "$_if_id" > /sys/bus/usb/drivers/rtl8851bu/bind 2>/dev/null
                    fi
                done
            fi
        fi
    done
}

# Pre-load 88x2bu.ko and 8851bu.ko unconditionally at daemon startup so the
# in-driver AOA blocker (dev.devt |= 0x00080000U in rtw_drv_init) runs immediately
# when the USB dongle is plugged in, before Android Auto usbfs can send AOA 51/52/53.
ensure_usb_wifi_modules_loaded() {
    [ "$HAS_BUILTIN_WIFI" = "1" ] && return 0

    trigger_usb_modeswitch

    # If module is still loaded with legacy interface name rtwlan0, reload as wlan0
    if [ -d /sys/class/net/rtwlan0 ]; then
        ip link set rtwlan0 down 2>/dev/null
        ip link set rtwlan1 down 2>/dev/null
        rmmod 88x2bu 2>/dev/null
        rmmod 8851bu 2>/dev/null
        sleep 1
    fi

    if ! grep -q "^88x2bu " /proc/modules 2>/dev/null; then
        if [ -f "$KO_88X2BU" ]; then
            insmod "$KO_88X2BU" rtw_country_code=KR rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_en_napi=0 rtw_en_gro=0 ifname=wlan%d if2name=p2p%d >>"$TMP_DIR/insmod.log" 2>&1
            if ! grep -q "^88x2bu " /proc/modules 2>/dev/null; then
                insmod "$KO_88X2BU" ifname=wlan%d if2name=p2p%d >>"$TMP_DIR/insmod.log" 2>&1
            fi
            grep -q "^88x2bu " /proc/modules 2>/dev/null && log_msg "Pre-loaded ${KO_88X2BU##*/} (ifname=wlan%d)"
        fi
    fi

    if ! grep -q "^8851bu " /proc/modules 2>/dev/null; then
        if [ -f "$KO_8851BU" ]; then
            insmod "$KO_8851BU" rtw_country_code=KR ifname=wlan%d if2name=p2p%d >>"$TMP_DIR/insmod.log" 2>&1
            if ! grep -q "^8851bu " /proc/modules 2>/dev/null; then
                insmod "$KO_8851BU" ifname=wlan%d if2name=p2p%d >>"$TMP_DIR/insmod.log" 2>&1
            fi
            grep -q "^8851bu " /proc/modules 2>/dev/null && log_msg "Pre-loaded ${KO_8851BU##*/} (ifname=wlan%d)"
        fi
    fi
}

# Check WifiApState via IWifiManager.getWifiApEnabledState() (transaction 30):
#   10 (0x0a) = WIFI_AP_STATE_DISABLING
#   11 (0x0b) = WIFI_AP_STATE_DISABLED
#   12 (0x0c) = WIFI_AP_STATE_ENABLING
#   13 (0x0d) = WIFI_AP_STATE_ENABLED
#   14 (0x0e) = WIFI_AP_STATE_FAILED
get_wifi_ap_state() {
    local _res
    _res="$(service call wifi 30 2>/dev/null)"
    case "$_res" in
        *0000000a*) echo 10 ;;
        *0000000b*) echo 11 ;;
        *0000000c*) echo 12 ;;
        *0000000d*) echo 13 ;;
        *0000000e*) echo 14 ;;
        *) echo 0 ;;
    esac
}

is_stock_hostapd_alive() {
    ps | grep "/system/bin/hostapd" | grep -v " Z " | grep -q "hostapd"
}

# Ensure LTE policy routing (table 61 / usb0) and NAT MASQUERADE for stock SoftAP
# subnet 192.168.0.0/24 whenever /system/bin/hostapd is running on wlan0
ensure_stock_hotspot_nat() {
    local _lte_if _cand
    if ! ip addr show dev wlan0 2>/dev/null | grep -q "192.168.0.1"; then
        ip addr add 192.168.0.1/24 broadcast 192.168.0.255 dev wlan0 2>/dev/null
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

    _lte_if=""
    for _cand in usb0 rmnet0 rmnet_data0 ccmni0 usb1; do
        if [ -d "/sys/class/net/$_cand" ] && ip addr show dev "$_cand" 2>/dev/null | grep -q "inet "; then
            _lte_if="$_cand"
            break
        fi
    done

    # EV6 / Gen5W Telechips LGE modem keeps the LTE default route in table 61
    if ip route show table 61 2>/dev/null | grep -q "default"; then
        if ! ip rule show 2>/dev/null | grep -q "to 192.168.0.0/24 lookup main"; then
            ip rule add pref 17900 to 192.168.0.0/24 lookup main 2>/dev/null
        fi
        if ! ip rule show 2>/dev/null | grep -q "from 192.168.0.0/24 lookup 61"; then
            ip rule add pref 18000 from 192.168.0.0/24 lookup 61 2>/dev/null
        fi
    fi

    if [ -n "$_lte_if" ]; then
        if ! iptables -t nat -C POSTROUTING -s 192.168.0.0/24 -o "$_lte_if" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -o "$_lte_if" -j MASQUERADE 2>/dev/null
        fi
        if ! iptables -C FORWARD -i wlan0 -o "$_lte_if" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i wlan0 -o "$_lte_if" -j ACCEPT 2>/dev/null
        fi
        if ! iptables -C FORWARD -i "$_lte_if" -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i "$_lte_if" -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
        fi
    fi
}

WLAN0_INITIALIZED=0
WLAN0_AUTOSTARTED=0

# Initialize wlan0 once per appearance on USB Wi-Fi vehicles:
# Calling 'ip link set wlan0 up' triggers _netdev_open -> firmware download ->
# rtw_cfg80211_init_wiphy (which registers 2.4GHz/5GHz HT40 capabilities on wiphy
# BEFORE /system/bin/hostapd queries NL80211_CMD_GET_WIPHY).
init_wlan0_on_appear() {
    local _ap_state _auto_prop
    if [ ! -d /sys/class/net/wlan0 ]; then
        if [ "$WLAN0_INITIALIZED" = "1" ] && [ "$HAS_BUILTIN_WIFI" = "0" ]; then
            _ap_state="$(get_wifi_ap_state)"
            if [ "$_ap_state" = "12" ] || [ "$_ap_state" = "13" ] || [ "$_ap_state" = "14" ] || is_stock_hostapd_alive; then
                log_msg "wlan0 removed -> resetting stock SoftAP state (was $_ap_state)"
                service call wifi 29 i32 0 i32 0 >/dev/null 2>&1
                ndc softap stopap >/dev/null 2>&1
            fi
        fi
        WLAN0_INITIALIZED=0
        WLAN0_AUTOSTARTED=0
        return 0
    fi

    if [ "$HAS_BUILTIN_WIFI" = "0" ] && [ "$WLAN0_INITIALIZED" != "1" ]; then
        log_msg "wlan0 detected -> bringing wlan0 UP to initialize Realtek firmware & wiphy capabilities"
        ip link set wlan0 up 2>/dev/null
        sleep 2
        prepare_stock_hotspot_env
        sync_bcmdhd_driver_status
        WLAN0_INITIALIZED=1
    fi

    # Optional one-shot auto-start ONLY if explicitly requested via persist.sys.hotspot.auto=1
    if [ "$WLAN0_AUTOSTARTED" != "1" ]; then
        _auto_prop="$(getprop persist.sys.hotspot.auto 2>/dev/null)"
        if [ "$_auto_prop" = "1" ]; then
            _ap_state="$(get_wifi_ap_state)"
            if ! is_stock_hostapd_alive && [ "$_ap_state" != "12" ] && [ "$_ap_state" != "13" ]; then
                log_msg "Auto-starting stock SoftAP on wlan0 (ap_state=$_ap_state)..."
                sync_bcmdhd_driver_status
                prepare_stock_hotspot_env
                service call wifi 29 i32 0 i32 1 >/dev/null 2>&1
            fi
        fi
        WLAN0_AUTOSTARTED=1
    fi

    # When SoftAP is active (hostapd alive), ensure 192.168.0.1/24, policy routing, and NAT
    if is_stock_hostapd_alive; then
        ensure_stock_hotspot_nat
    fi
}

# Initial setup on daemon startup:
# MUST pre-load 88x2bu + 8851bu FIRST, then load [permanent] bcmdhd_stub LAST
# so "bcmdhd" is guaranteed to be on Line 1 of /proc/modules!
prepare_stock_hotspot_env
ensure_usb_wifi_modules_loaded
sync_bcmdhd_driver_status

# Re-check built-in SDIO Wi-Fi after 2s in case mmc1 finished probing late at boot
if [ "$HAS_BUILTIN_WIFI" = "0" ]; then
    if [ -e /sys/bus/mmc/devices/mmc1:0001 ] || [ -e /sys/bus/sdio/devices/mmc1:0001:1 ]; then
        HAS_BUILTIN_WIFI=1
        log_msg "Late-detected built-in Broadcom SDIO Wi-Fi (mmc1:0001)."
    fi
fi

# Main monitoring loop (1s interval so wlan.driver.status=ok is restored immediately
# whenever wifi_unload_driver() sets it to "unloading" on Hotspot OFF)
while true; do
    prepare_stock_hotspot_env
    ensure_usb_wifi_modules_loaded
    sync_bcmdhd_driver_status
    init_wlan0_on_appear
    sleep 1
done
"""


def write_text_lf(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content.replace("\r\n", "\n"))


def parse_nemesis_ini(raw_bytes):
    """Exact replica of /system/bin/nemesis sub_03c20 INI parser."""
    if raw_bytes.startswith(b"\xef\xbb\xbf"):
        raise RuntimeError(
            "NEMESIS.data has UTF-8 BOM (breaks sub_03c20 [section] parser)"
        )
    if b"\r" in raw_bytes:
        raise RuntimeError("NEMESIS.data contains CR (\\r) line endings")
    sections = {}
    cur_sec = None
    for line in raw_bytes.decode("utf-8").split("\n"):
        line = line.strip(" \t")
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("["):
            if not line.endswith("]") or len(line) <= 2:
                raise RuntimeError(f"Invalid section header: {line!r}")
            cur_sec = line[1:-1]
            sections.setdefault(cur_sec, {})
        else:
            if cur_sec is None or "=" not in line:
                raise RuntimeError(
                    f"Key-value outside section or missing '=': {line!r}"
                )
            k, v = line.split("=", 1)
            sections[cur_sec][k.strip(" \t")] = v.strip(" \t")
    return sections


def verify_nemesis_bundles(inner_zip_path, outer_zip_path):
    print(
        "\n=== Step 5: Verifying NEMESIS Binary Compatibility (/system/bin/nemesis) ==="
    )
    # 1. Verify outer USB bundle (usb-handler @ 0x0a03c)
    with zipfile.ZipFile(outer_zip_path, "r") as ozf:
        outer_names = ozf.namelist()
        if "NEMESIS.data" not in outer_names:
            raise RuntimeError("Outer zip missing root NEMESIS.data")
        usb_ini = parse_nemesis_ini(ozf.read("NEMESIS.data"))
        nem_sec = usb_ini.get("nemesis", {})
        if nem_sec.get("type") != "install":
            raise RuntimeError(
                f"Outer NEMESIS.data invalid type: {nem_sec.get('type')!r}"
            )
        pkg_rel = nem_sec.get("path", "")
        if not pkg_rel or pkg_rel.startswith(("/", "\\")) or ".." in pkg_rel:
            raise RuntimeError(f"Outer NEMESIS.data invalid path: {pkg_rel!r}")
        if pkg_rel not in outer_names:
            raise RuntimeError(f"Outer zip missing target package: {pkg_rel}")
        print(
            f"  [OK] Outer USB descriptor: [nemesis] type={nem_sec['type']}, path={pkg_rel}"
        )

    # 2. Verify inner package zip (nemesis install @ 0x05534 & sub_0636c)
    with zipfile.ZipFile(inner_zip_path, "r") as izf:
        inner_names = izf.namelist()
        if "NEMESIS.data" not in inner_names:
            raise RuntimeError("Inner package zip missing root NEMESIS.data")
        pkg_ini = parse_nemesis_ini(izf.read("NEMESIS.data"))
        p_nem = pkg_ini.get("nemesis", {})
        pkg_id = p_nem.get("id", "")
        if not pkg_id or pkg_id.startswith(".") or ".." in pkg_id or len(pkg_id) > 64:
            raise RuntimeError(f"Invalid package id: {pkg_id!r}")
        for req_path in [
            p_nem.get("postinstall"),
            p_nem.get("preuninstall"),
            pkg_ini.get("app.0", {}).get("path"),
            pkg_ini.get("service.0", {}).get("path"),
        ]:
            if not req_path or req_path not in inner_names:
                raise RuntimeError(
                    f"Inner package missing required script: {req_path!r}"
                )
        for req_ko in list(KO_PATCH_SPECS.keys()) + list(BCMDHD_STUB_SPECS.keys()):
            if f"modules/{req_ko}" not in inner_names:
                raise RuntimeError(f"Inner package missing module: modules/{req_ko}")
        print(
            f"  [OK] Inner package descriptor: id={pkg_id}, version={p_nem.get('version')}, "
            f"types={p_nem.get('types')}, modules={len(KO_PATCH_SPECS) + len(BCMDHD_STUB_SPECS)}"
        )


def build_nemesis_package():
    if os.path.exists(PKG_SRC_DIR):
        shutil.rmtree(PKG_SRC_DIR)
    if os.path.exists(USB_ROOT_DIR):
        shutil.rmtree(USB_ROOT_DIR)

    # Remove stale draft files from BASE_DIR if left over from earlier draft
    for stale_file in ["stock.hotspot.nemesis", "NEMESIS.data"]:
        stale_path = os.path.join(BASE_DIR, stale_file)
        if os.path.exists(stale_path):
            os.remove(stale_path)
    for stale_dir in ["bin", "scripts", "svc"]:
        stale_dpath = os.path.join(BASE_DIR, stale_dir)
        if os.path.exists(stale_dpath):
            shutil.rmtree(stale_dpath)

    print("=== Step 1: Building & Verifying Stock Hotspot Kernel Modules (.ko) ===")
    build_and_verify_ko_modules()

    print("\n=== Step 2: Staging NEMESIS Package Contents (pkg_src) ===")
    write_text_lf(os.path.join(PKG_SRC_DIR, "NEMESIS.data"), PKG_META)
    write_text_lf(os.path.join(PKG_SRC_DIR, "scripts", "post.sh"), POST_SH)
    write_text_lf(os.path.join(PKG_SRC_DIR, "scripts", "preun.sh"), PREUN_SH)
    write_text_lf(os.path.join(PKG_SRC_DIR, "bin", "launch.sh"), LAUNCH_SH)
    write_text_lf(
        os.path.join(PKG_SRC_DIR, "svc", "stock-hotspot-daemon.sh"), DAEMON_SH
    )

    pkg_mod_dir = os.path.join(PKG_SRC_DIR, "modules")
    os.makedirs(pkg_mod_dir, exist_ok=True)
    all_ko_names = sorted(list(KO_PATCH_SPECS.keys()) + list(BCMDHD_STUB_SPECS.keys()))
    for ko_name in all_ko_names:
        shutil.copy2(
            os.path.join(DST_MODULES_DIR, ko_name),
            os.path.join(pkg_mod_dir, ko_name),
        )

    print(
        "\n=== Step 3: Creating Inner NEMESIS Package (packages/stock.hotspot.zip) ==="
    )
    inner_zip_path = os.path.join(USB_ROOT_DIR, "packages", "stock.hotspot.zip")
    os.makedirs(os.path.dirname(inner_zip_path), exist_ok=True)
    with zipfile.ZipFile(inner_zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(PKG_SRC_DIR):
            for file in sorted(files):
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, PKG_SRC_DIR).replace("\\", "/")
                zf.write(full_path, rel_path)

    write_text_lf(os.path.join(USB_ROOT_DIR, "NEMESIS.data"), USB_META)
    print(
        f"  [OK] Created {inner_zip_path} ({os.path.getsize(inner_zip_path):,} bytes)"
    )

    print(
        "\n=== Step 4: Creating Outer USB Installation Bundle (HKG_5W_Stock_Hotspot.zip) ==="
    )
    with zipfile.ZipFile(OUTER_ZIP_PATH, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(USB_ROOT_DIR):
            for file in sorted(files):
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, USB_ROOT_DIR).replace("\\", "/")
                zf.write(full_path, rel_path)

    print(
        f"  [OK] Created {OUTER_ZIP_PATH} ({os.path.getsize(OUTER_ZIP_PATH):,} bytes)"
    )

    verify_nemesis_bundles(inner_zip_path, OUTER_ZIP_PATH)


if __name__ == "__main__":
    build_nemesis_package()
