#!/usr/bin/env bash
#
# flash-k3-firmware.sh — flash SpacemiT K3 (Pico-ITX / Com260) firmware only
#
# Instead of flashing SpacemiT's full all-in-one OS image just to get
# firmware, this script downloads only the firmware .deb packages we publish
# in ppa:ubuntu-risc-v-team/k3, extracts the payloads, and uses SpacemiT's
# own image_flash.py to push them to the board's SPI NOR over USB fastboot.
#
# What gets flashed (SPI NOR, MTD partition layout):
#
#   partition   payload                      source package
#   ----------  -------------------------    ------------------------
#   bootinfo    bootinfo_spinor.bin          u-boot-spacemit
#   fsbl        FSBL.bin  (== FDL1)          u-boot-spacemit
#   env         env.bin                      u-boot-spacemit
#   esos        esos.itb                     esos-spacemit
#   opensbi     fw_dynamic.itb               opensbi-spacemit
#   uboot       edk2.itb  (UEFI system FW)   edk2-spacemit
#
# The EC (Chromium-EC) controller is also flashed if spacemit-ec-firmware is
# available: SpacemiT's fastboot.yaml stages ec.bin and issues `oem ec:flash`,
# which the U-Boot running in RAM executes over I2C.  This is best-effort
# (skip_fail); the factory EC is fine to boot from.
#
# Package download uses pull-ppa-debs (ubuntu-dev-tools) — the same standard
# tool SpacemiT's gadget.in/Makefile uses, but pointed at our PPA instead of
# theirs.  The actual flashing protocol — FDL1/FDL2 staging into RAM, MTD
# partition table write, USB speed negotiation, EC flash, retries — is handled
# by SpacemiT's image_flash.py + fastboot.yaml, fetched from their
# K3-Ubuntu-Images repository.
#
# The block device (UFS/eMMC) is left untouched.  After firmware is flashed,
# dd an official Ubuntu preinstalled image directly onto the board's storage.
#
# Usage:
#   ./flash-k3-firmware.sh            # flash latest firmware from the PPA
#
# Override the Ubuntu suite the PPA is built for:
#   K3_FLASH_SUITE=resolute ./flash-k3-firmware.sh
# Skip the post-flash readback verification:
#   K3_VERIFY=0 ./flash-k3-firmware.sh
#
# Pre-requisites on the host: ubuntu-dev-tools (pull-ppa-debs), dpkg, git,
# python3, python3-yaml, python3-usb (readback verification), fastboot.
# Run with a board in FDL flash mode (hold the FDL button while powering on)
# and a USB-C data cable to the host.
#
# Copyright (C) 2026 Canonical Ltd.
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

PPA="ubuntu-risc-v-team/k3"
SUITE="${K3_FLASH_SUITE:-resolute}"   # Ubuntu release the PPA is built for
WORKDIR="$(mktemp -d -t k3-firmware-XXXXXX)"
SPACEMIT_REPO="https://github.com/spacemit-com/K3-Ubuntu-Images.git"

# Source packages to pull from the PPA.  pull-ppa-debs takes a SOURCE package
# name and downloads all resulting binary .debs.  The u-boot-spacemit source
# produces two binaries: u-boot-spl-spacemit (FSBL, bootinfo, env) and
# u-boot-spacemit (u-boot.itb) — both are extracted into the same tree.
declare -A SOURCE_PKGS=(
  [u-boot-spacemit]=1
  [edk2-spacemit]=1
  [opensbi-spacemit]=1
  [esos-spacemit]=1
)
# Optional: not fatal if missing from the PPA.
OPTIONAL_SOURCE="spacemit-ec-firmware"

# Firmware payloads: temp-filename = "source_pkg:/path/in/extracted/.deb"
# These map to the flat files image_flash.py expects in ./temp/.
declare -A PAYLOADS=(
  [FSBL.bin]="u-boot-spacemit:/usr/lib/u-boot/spacemit/FSBL.bin"
  [bootinfo_spinor.bin]="u-boot-spacemit:/usr/lib/u-boot/spacemit/bootinfo_spinor.bin"
  [env.bin]="u-boot-spacemit:/usr/lib/u-boot/spacemit/env.bin"
  [u-boot.itb]="u-boot-spacemit:/usr/lib/u-boot/spacemit/u-boot.itb"
  [edk2.itb]="edk2-spacemit:/usr/lib/uefi/spacemit/edk2.itb"
  [fw_dynamic.itb]="opensbi-spacemit:/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.itb"
  [esos.itb]="esos-spacemit:/usr/lib/riscv64-linux-gnu/esos/esos.itb"
  [ec.bin]="spacemit-ec-firmware:/lib/firmware/k3-pico-itx/ec.bin"
)

# Firmware-only partition names (passed to image_flash.py --only).
# This restricts multi_flash to firmware partitions, skipping OS partitions
# (esp, cidata, writable) that would otherwise fail (no image extracted).
FIRMWARE_PARTITIONS="bootinfo,fsbl,env,esos,opensbi,uboot"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Check for dependencies, add missing dependencies to array
# and print them all to user, with automatic prompt to install
missing=()
need() { command -v "$1" >/dev/null 2>&1 || missing+=("$2"); }
need pull-ppa-debs ubuntu-dev-tools
need dpkg-deb dpkg
need fastboot fastboot
need git git
need python3 python3
python3 -c 'import yaml' 2>/dev/null || missing+=(python3-yaml)
# python3-usb is only needed for the post-flash readback verification, so
# only require it when that is enabled.
if [[ "${K3_VERIFY:-1}" == "1" ]]; then
  python3 -c 'import usb' 2>/dev/null || missing+=(python3-usb)
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  warn "missing dependencies: ${missing[*]}"
  if [[ ! -t 0 ]]; then
    die "install them manually: sudo apt install ${missing[*]}"
  fi
  read -rp "Install now with apt? [Y/n] " install_ans || install_ans=""
  if [[ "${install_ans:-y}" =~ ^[Yy]$ ]]; then
    sudo apt install -y "${missing[@]}"
  else
    die "install them manually: sudo apt install ${missing[*]}"
  fi
fi

# ---------------------------------------------------------- PPA pull + extract --

declare -A EXTRACTED=()   # source_pkg -> extraction root

# Pull a source package's binary .debs from the PPA via pull-ppa-debs and
# extract them all into a single tree.  $2 = "optional" to warn-and-continue
# instead of dying.
pull_source() {
  local src="$1" mode="${2:-required}" dir deb
  dir="$WORKDIR/extract/$src"
  if [[ -d "$dir" ]]; then
    EXTRACTED[$src]="$dir"
    return 0
  fi
  mkdir -p "$dir"
  log "pulling $src from ppa:$PPA ($SUITE)..."
  if ! ( cd "$dir" && pull-ppa-debs --no-verify-signature --ppa="$PPA" -a riscv64 "$src" "$SUITE" ); then
    if [[ "$mode" == "optional" ]]; then
      warn "optional $src not available — EC firmware will be skipped"
      return 1
    fi
    die "failed to pull $src from ppa:$PPA (suite $SUITE)"
  fi
  # Extract all downloaded .debs into the same root.
  for deb in "$dir"/*.deb; do
    [[ -s "$deb" ]] || continue
    dpkg-deb -x "$deb" "$dir"
  done
  EXTRACTED[$src]="$dir"
}


# -------------------------------------------------------- SpacemiT flasher ------

SPACEMIT_DIR="$WORKDIR/spacemit"
TEMP_DIR="$SPACEMIT_DIR/temp"

clone_spacemit() {
  if [[ -d "$SPACEMIT_DIR/.git" ]]; then
    log "SpacemiT repo already cloned"
  else
    log "cloning SpacemiT K3-Ubuntu-Images..."
    git clone --depth 1 "$SPACEMIT_REPO" "$SPACEMIT_DIR"
  fi
}

# Copy extracted payloads flat into ./temp/ — the layout image_flash.py
# expects.  Files referenced by fastboot.yaml (stage + partition flash)
# are looked up as TEMP_DIR / basename, so the factory/ prefix in the
# partition JSON is immaterial.
populate_temp() {
  mkdir -p "$TEMP_DIR"
  local name spec pkg rel src
  for name in "${!PAYLOADS[@]}"; do
    spec="${PAYLOADS[$name]}"
    pkg="${spec%%:*}"
    [[ -n "${EXTRACTED[$pkg]:-}" ]] || continue   # skip if source not pulled
    rel="${spec#*:}"
    src="${EXTRACTED[$pkg]}$rel"
    if [[ -s "$src" ]]; then
      cp "$src" "$TEMP_DIR/$name"
      log "  $name  <-  $pkg"
    else
      warn "payload not available: $name ($pkg) — will be skipped by image_flash.py"
    fi
  done
}

# Delegate the entire fastboot protocol to SpacemiT's image_flash.py:
#   - FDL1 staging (FSBL.bin → RAM, brings up DRAM + USB)
#   - FDL2 staging (u-boot.itb → RAM, full fastboot server)
#   - EC firmware   (stage ec.bin + oem ec:flash, best-effort)
#   - MTD partition table write + per-partition flash (SPI NOR)
#   - GPT partition table write + firmware partitions
#
# --only restricts to firmware partitions so esp/cidata/writable (which we
# don't extract) are skipped instead of causing a fastboot error.
flash_board() {
  log "flashing firmware via SpacemiT image_flash.py..."
  ( cd "$SPACEMIT_DIR" && \
    python3 image_flash.py \
      --fastboot fastboot.yaml \
      --only "$FIRMWARE_PARTITIONS" )
}

# Post-flash readback verification.  The agent's built-in check compares the
# flash against the *download buffer*, so corruption entering over USB (host
# side) passes it, and the additive checksum it uses is blind to block
# reordering.  Here we read each flashed MTD partition back over fastboot
# ("oem read" stock command, see fastboot-dump.py) and md5-compare against the
# file we staged.  The agent idles in its fastboot loop after image_flash.py
# finishes, so this runs in the same session.
#
# env is skipped on purpose: the agent legitimately re-saves it with updated
# runtime content, so partition bytes != env.bin is expected there.
verify_board() {
  if [[ "${K3_VERIFY:-1}" != "1" ]]; then
    log "verify: disabled (K3_VERIFY=0)"
    return 0
  fi
  local tool
  tool="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fastboot-dump.py"
  if [[ ! -x "$tool" ]]; then
    warn "verify: $tool not found — skipping readback check"
    return 0
  fi

  local -A part_file=(
    [bootinfo]=bootinfo_spinor.bin
    [fsbl]=FSBL.bin
    [esos]=esos.itb
    [opensbi]=fw_dynamic.itb
    [uboot]=edk2.itb
  )
  local part file want got
  for part in ${FIRMWARE_PARTITIONS//,/ }; do
    file="${part_file[$part]:-}"
    [[ -n "$file" && -s "$TEMP_DIR/$file" ]] || continue
    log "verify: reading back '$part'..."
    if ! "$tool" "$part" "$WORKDIR/verify-$part.bin" >&2; then
      warn "verify: could not read back '$part' (old agent without oem read?) — skipping"
      continue
    fi
    want=$(md5sum < "$TEMP_DIR/$file" | cut -d' ' -f1)
    got=$(head -c "$(stat -c%s "$TEMP_DIR/$file")" "$WORKDIR/verify-$part.bin" | md5sum | cut -d' ' -f1)
    if [[ "$want" == "$got" ]]; then
      log "verify: $part OK ($file, md5 $want)"
    else
      err "verify: $part MISMATCH (expected $want, read back $got)"
      err "verify: the board is still in FDL/fastboot mode — re-run this script to re-flash and recover."
      exit 1
    fi
  done
}

# ---------------------------------------------------------------- main --------

trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR"

log "K3 firmware flasher"
log "  PPA:     ppa:$PPA"
log "  suite:   $SUITE"
log "  workdir: $WORKDIR"
echo

# Pull and extract all firmware source packages.
for src in "${!SOURCE_PKGS[@]}"; do
  pull_source "$src" required
done
pull_source "$OPTIONAL_SOURCE" optional || true
echo

clone_spacemit
populate_temp

log "payloads in $TEMP_DIR:"
ls -1 "$TEMP_DIR" 2>/dev/null | sed 's/^/  /' || warn "no payloads extracted"
log "About to flash firmware to the board via USB fastboot."
log "Ensure the board is in FDL flash mode (hold FDL button while powering on)."
warn "Once flashing starts, do **not** interrupt it, or you could brick your board!"
read -rp "Continue? [y/N] " confirm || die "aborted (no input)"
[[ "$confirm" =~ ^[Yy]$ ]] || die "aborted by user"
echo

flash_board
verify_board

cat <<'EOF'

==============================================================================
 Firmware flashed. Please reboot the board.

 Next: install Ubuntu on the board's storage (NVMe/UFS), using an installer
 image on an USB thumb drive. Press F2 when EDK2 loads to enter EDK2 menu and
 select boot device.

 Once Ubuntu is up, make sure to maintain all firmware up to date:
   sudo add-apt-repository ppa:ubuntu-risc-v-team/k3
   sudo apt update && sudo apt install spacemit-firmware
==============================================================================
EOF
