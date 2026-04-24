#!/bin/bash
################################################################################
# Homelabs - Arch Linux Bootable USB Creator
# Creates a USB drive for bare-metal Arch Linux installation
#
# Supports two modes:
#   1) ISO mode  — Downloads the latest Arch ISO and writes it to USB (dd)
#   2) Netboot   — Creates a UEFI USB with iPXE netboot (always boots latest)
################################################################################

set -euo pipefail

################################################################################
# Constants
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ARCH_MIRROR="https://geo.mirror.pkgbuild.com"
ARCH_NETBOOT_URL="https://archlinux.org/static/netboot/ipxe-arch.efi"
ARCH_NETBOOT_BIOS_URL="https://archlinux.org/static/netboot/ipxe-arch.lkrn"
WORK_DIR="/tmp/arch-usb-creator-$$"

# Populated during execution
DISK=""
MODE=""          # "iso" or "netboot"
ISO_PATH=""      # Path to downloaded/provided ISO
SKIP_DOWNLOAD=false

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✔ $1${NC}"; }
print_error()   { echo -e "${RED}✖ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }
print_step()    { echo -e "${CYAN}▶ $1${NC}"; }

cleanup() {
    if [[ -d "$WORK_DIR" ]]; then
        print_info "Cleaning up temporary files..."
        # Unmount anything we may have mounted
        umount "${WORK_DIR}/mnt" 2>/dev/null || true
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat << 'EOF'
Usage: create-arch-boot-usb.sh [OPTIONS]

Creates a bootable Arch Linux USB drive for bare-metal installation.

MODE (pick one):
    --iso               Write latest Arch ISO to USB (classic dd approach)
    --netboot           Create UEFI netboot USB with iPXE (always latest Arch)

OPTIONAL:
    --disk DEVICE       Target USB device (e.g., /dev/sdb). Interactive if omitted.
    --iso-file PATH     Use a local ISO file instead of downloading
    --help              Show this help

EXAMPLES:
    # Interactive — choose mode and disk from menus
    ./create-arch-boot-usb.sh

    # Write latest ISO to /dev/sdb
    ./create-arch-boot-usb.sh --iso --disk /dev/sdb

    # Create netboot USB (tiny, always boots latest Arch)
    ./create-arch-boot-usb.sh --netboot --disk /dev/sdb

    # Use a local ISO you already downloaded
    ./create-arch-boot-usb.sh --iso --iso-file ~/Downloads/archlinux-2026.02.01-x86_64.iso

NETBOOT vs ISO:
    Netboot (recommended for USB3 + wired Ethernet):
      ✔ Tiny image (~1 MB), always boots the latest Arch release
      ✔ No need to re-flash for new releases
      ✔ Requires wired Ethernet during boot
      ✔ USB drive stays reusable for other files (only ~2 MB used)

    ISO (classic):
      ✔ Works offline / without network during boot
      ✔ Full live environment on USB
      ✖ Must re-flash for each new Arch release (~800 MB download)
EOF
    exit 0
}

################################################################################
# Dependency Checks
################################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (or with sudo)"
        exit 1
    fi
}

check_dependencies() {
    print_info "Checking dependencies..."

    local deps=()
    local missing=()

    # Always needed
    deps+=(lsblk wipefs parted mkfs.fat curl)

    # ISO mode needs dd + optional gpg verification
    if [[ "$MODE" == "iso" ]]; then
        deps+=(dd)
    fi

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required tools: ${missing[*]}"
        print_info "Install them with your package manager, e.g.:"
        print_info "  pacman -S parted dosfstools curl coreutils"
        print_info "  apt install parted dosfstools curl coreutils"
        exit 1
    fi

    print_success "All dependencies found"
}

################################################################################
# Disk Selection
################################################################################

list_removable_disks() {
    # List only removable (USB) block devices, exclude loop/rom/partition
    lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL,RM \
        | awk 'NR==1 || ($3=="disk" && ($4=="usb" || $6=="1"))'
}

get_removable_disks() {
    # Return array of /dev/sdX paths that are removable USB drives
    lsblk -d -n -o NAME,TYPE,TRAN,RM \
        | awk '($2=="disk" && ($3=="usb" || $4=="1")) {print "/dev/"$1}'
}

select_disk() {
    print_header "Select Target USB Drive"

    echo ""
    print_info "Detected removable drives:"
    echo ""
    list_removable_disks
    echo ""

    local disks
    mapfile -t disks < <(get_removable_disks)

    if [[ ${#disks[@]} -eq 0 ]]; then
        print_error "No removable USB drives detected!"
        print_info "Make sure your USB drive is plugged in."
        print_info ""
        print_info "All block devices:"
        lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL
        exit 1
    fi

    echo "  Available USB drives:"
    echo ""
    for i in "${!disks[@]}"; do
        local dev="${disks[$i]}"
        local model size
        model="$(lsblk -d -n -o MODEL "$dev" 2>/dev/null | xargs)"
        size="$(lsblk -d -n -o SIZE "$dev" 2>/dev/null | xargs)"
        printf "    %d) %-12s  %8s  %s\n" "$((i+1))" "$dev" "$size" "$model"
    done
    echo ""

    while true; do
        read -rp "  Select drive number: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#disks[@]} )); then
            DISK="${disks[$((sel-1))]}"
            break
        fi
        print_error "Invalid selection — enter a number between 1 and ${#disks[@]}"
    done

    # Safety check: refuse to write to mounted disks
    if mount | grep -q "^${DISK}"; then
        print_error "$DISK has mounted partitions! Unmount them first:"
        mount | grep "^${DISK}"
        exit 1
    fi

    # Double confirmation
    local disk_model disk_size
    disk_model="$(lsblk -d -n -o MODEL "$DISK" 2>/dev/null | xargs)"
    disk_size="$(lsblk -d -n -o SIZE "$DISK" 2>/dev/null | xargs)"

    echo ""
    print_warning "╔══════════════════════════════════════════════════════════╗"
    print_warning "║  ALL DATA ON THIS DEVICE WILL BE PERMANENTLY DESTROYED  ║"
    print_warning "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Device:  $DISK"
    echo "  Size:    $disk_size"
    echo "  Model:   $disk_model"
    echo ""

    read -rp "  Type 'YES' to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        print_error "Aborted by user"
        exit 1
    fi
}

validate_disk() {
    # Validate --disk argument
    if [[ ! -b "$DISK" ]]; then
        print_error "$DISK is not a valid block device"
        exit 1
    fi

    # Check it's not a partition
    local dtype
    dtype="$(lsblk -d -n -o TYPE "$DISK" 2>/dev/null)"
    if [[ "$dtype" != "disk" ]]; then
        print_error "$DISK does not appear to be a whole disk (type: $dtype)"
        print_info "Specify the whole device, e.g., /dev/sdb (not /dev/sdb1)"
        exit 1
    fi

    # Warn if it doesn't look like a USB drive
    local tran rm_flag
    tran="$(lsblk -d -n -o TRAN "$DISK" 2>/dev/null | xargs)"
    rm_flag="$(lsblk -d -n -o RM "$DISK" 2>/dev/null | xargs)"
    if [[ "$tran" != "usb" && "$rm_flag" != "1" ]]; then
        print_warning "$DISK does not appear to be a removable USB drive (tran=$tran, removable=$rm_flag)"
        read -rp "  Continue anyway? (y/n): " answer
        if [[ "$answer" != "y" ]]; then
            print_error "Aborted"
            exit 1
        fi
    fi
}

################################################################################
# Mode Selection
################################################################################

select_mode() {
    print_header "Select Boot Mode"

    cat << 'EOF'

  Choose how to create your Arch Linux boot USB:

    1) Netboot (recommended)
       • Tiny (~1 MB iPXE image), always boots the LATEST Arch release
       • Requires wired Ethernet on the target machine during boot
       • No need to re-flash the USB for new Arch releases
       • USB drive remains mostly free for other files

    2) ISO (classic)
       • Downloads the full latest Arch ISO (~800 MB)
       • Works without network during initial boot
       • Must re-flash the USB for each new Arch release
       • Entire USB is dedicated to the ISO

EOF

    while true; do
        read -rp "  Select mode (1=netboot, 2=iso): " sel
        case "$sel" in
            1) MODE="netboot"; break ;;
            2) MODE="iso";     break ;;
            *) print_error "Invalid selection — enter 1 or 2" ;;
        esac
    done

    print_success "Mode: $MODE"
}

################################################################################
# ISO Mode
################################################################################

detect_latest_iso() {
    print_step "Detecting latest Arch Linux ISO..."

    # The mirror's /iso/latest/ directory always has the current release
    local iso_name
    iso_name="$(curl -sL "${ARCH_MIRROR}/iso/latest/" \
        | grep -oP 'archlinux-\d{4}\.\d{2}\.\d{2}-x86_64\.iso(?=\")' \
        | head -1)"

    if [[ -z "$iso_name" ]]; then
        print_error "Could not detect the latest ISO filename from mirror"
        print_info "Try: ${ARCH_MIRROR}/iso/latest/"
        exit 1
    fi

    echo "$iso_name"
}

download_iso() {
    print_header "Downloading Arch Linux ISO"

    mkdir -p "$WORK_DIR"

    if [[ "$SKIP_DOWNLOAD" == "true" && -f "$ISO_PATH" ]]; then
        print_info "Using local ISO: $ISO_PATH"
        return
    fi

    local iso_name
    iso_name="$(detect_latest_iso)"
    ISO_PATH="${WORK_DIR}/${iso_name}"

    local iso_url="${ARCH_MIRROR}/iso/latest/${iso_name}"
    local sig_url="${iso_url}.sig"
    local sha_url="${ARCH_MIRROR}/iso/latest/sha256sums.txt"

    print_info "ISO:    $iso_name"
    print_info "URL:    $iso_url"
    print_info "Target: $ISO_PATH"
    echo ""

    # Download ISO with progress
    print_step "Downloading ISO (this may take a while on slow connections)..."
    curl -L --progress-bar -o "$ISO_PATH" "$iso_url"
    print_success "ISO downloaded: $(du -h "$ISO_PATH" | cut -f1)"

    # Download and verify SHA256
    print_step "Verifying SHA256 checksum..."
    local sha_file="${WORK_DIR}/sha256sums.txt"
    curl -sL -o "$sha_file" "$sha_url"

    local expected_sha
    expected_sha="$(grep "$iso_name" "$sha_file" | awk '{print $1}')"

    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha="$(sha256sum "$ISO_PATH" | awk '{print $1}')"

        if [[ "$expected_sha" == "$actual_sha" ]]; then
            print_success "SHA256 checksum verified ✓"
        else
            print_error "SHA256 MISMATCH!"
            print_error "  Expected: $expected_sha"
            print_error "  Got:      $actual_sha"
            print_error "The download may be corrupted. Aborting."
            exit 1
        fi
    else
        print_warning "Could not find SHA256 for $iso_name — skipping verification"
    fi

    # Optional: GPG signature verification
    if command -v gpg &>/dev/null; then
        print_step "Downloading GPG signature..."
        local sig_file="${WORK_DIR}/${iso_name}.sig"
        if curl -sL -o "$sig_file" "$sig_url" 2>/dev/null; then
            print_info "Verifying GPG signature (may need Arch signing keys)..."
            if gpg --keyserver-options auto-key-retrieve \
                   --verify "$sig_file" "$ISO_PATH" 2>/dev/null; then
                print_success "GPG signature verified ✓"
            else
                print_warning "GPG verification failed (missing keys?). Continuing with SHA256 only."
            fi
        fi
    else
        print_info "gpg not found — skipping GPG signature verification"
    fi
}

write_iso_to_usb() {
    print_header "Writing ISO to USB"

    print_info "Target device: $DISK"
    print_info "ISO file:      $ISO_PATH"
    print_info "ISO size:      $(du -h "$ISO_PATH" | cut -f1)"
    echo ""

    # Unmount any partitions on the target disk
    print_step "Unmounting any partitions on $DISK..."
    for part in "${DISK}"*; do
        umount "$part" 2>/dev/null || true
    done

    # Write with dd, showing progress
    print_step "Writing ISO to $DISK (this takes a few minutes)..."
    echo ""

    dd if="$ISO_PATH" of="$DISK" bs=4M status=progress oflag=sync conv=fsync

    print_step "Flushing buffers..."
    sync

    print_success "ISO written to $DISK"
}

################################################################################
# Netboot Mode
################################################################################

create_netboot_usb() {
    print_header "Creating Netboot USB (iPXE)"

    mkdir -p "$WORK_DIR/mnt"

    # ── Step 1: Partition the USB drive ──────────────────────────────────────
    print_step "Partitioning $DISK (GPT + EFI System Partition)..."

    # Unmount everything first
    for part in "${DISK}"*; do
        umount "$part" 2>/dev/null || true
    done

    # Wipe and create fresh GPT with a single EFI partition
    wipefs -af "$DISK" 2>/dev/null || true
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart "EFI" fat32 1MiB 512MiB
    parted -s "$DISK" set 1 esp on

    # If there's space left, create a data partition for general use
    local disk_size_mb
    disk_size_mb="$(lsblk -d -n -o SIZE -b "$DISK" | awk '{printf "%d", $1/1024/1024}')"
    if (( disk_size_mb > 600 )); then
        parted -s "$DISK" mkpart "Data" fat32 512MiB 100%
        print_info "Created additional data partition for general use"
    fi

    sleep 2
    partprobe "$DISK"
    sleep 2
    udevadm settle

    # Determine partition device name
    local esp_part
    if [[ "$DISK" =~ nvme|mmcblk ]]; then
        esp_part="${DISK}p1"
    else
        esp_part="${DISK}1"
    fi

    print_success "Partitioned: ESP = $esp_part"

    # ── Step 2: Format EFI partition ─────────────────────────────────────────
    print_step "Formatting $esp_part as FAT32..."
    mkfs.fat -F32 -n "ARCHBOOT" "$esp_part"
    print_success "Formatted"

    # Format data partition if it exists
    local data_part=""
    if [[ "$DISK" =~ nvme|mmcblk ]]; then
        data_part="${DISK}p2"
    else
        data_part="${DISK}2"
    fi
    if [[ -b "$data_part" ]]; then
        print_step "Formatting data partition $data_part as FAT32..."
        mkfs.fat -F32 -n "USBDATA" "$data_part"
        print_success "Data partition formatted"
    fi

    # ── Step 3: Mount and populate ───────────────────────────────────────────
    print_step "Mounting $esp_part..."
    mount "$esp_part" "${WORK_DIR}/mnt"

    # Create EFI directory structure
    mkdir -p "${WORK_DIR}/mnt/EFI/boot"
    mkdir -p "${WORK_DIR}/mnt/arch/netboot"

    # ── Step 4: Download iPXE images ─────────────────────────────────────────
    print_step "Downloading Arch Linux iPXE netboot image (UEFI)..."
    curl -L --progress-bar -o "${WORK_DIR}/mnt/EFI/boot/bootx64.efi" "$ARCH_NETBOOT_URL"
    print_success "Downloaded: ipxe-arch.efi → EFI/boot/bootx64.efi"

    # Also download BIOS version for legacy boot compatibility
    print_step "Downloading Arch Linux iPXE netboot image (BIOS)..."
    curl -L --progress-bar -o "${WORK_DIR}/mnt/arch/netboot/ipxe-arch.lkrn" "$ARCH_NETBOOT_BIOS_URL"
    print_success "Downloaded: ipxe-arch.lkrn"

    # ── Step 5: Create a startup.nsh as UEFI shell fallback ──────────────────
    cat > "${WORK_DIR}/mnt/startup.nsh" << 'STARTUP'
@echo -off
echo "Arch Linux Netboot — Starting iPXE..."
\EFI\boot\bootx64.efi
STARTUP
    print_success "Created startup.nsh (UEFI Shell fallback)"

    # ── Step 6: Create a README on the drive ─────────────────────────────────
    cat > "${WORK_DIR}/mnt/README.txt" << 'README'
================================================================================
  Arch Linux Netboot USB
================================================================================

This USB drive boots Arch Linux via iPXE Netboot.

HOW TO USE:
  1. Plug this USB into the target machine
  2. Connect the target machine to wired Ethernet
  3. Boot from this USB (enter BIOS/UEFI boot menu, usually F12/F2/DEL)
  4. Disable Secure Boot if prompted
  5. iPXE will start, connect to the network, and present a boot menu
  6. Select your preferred mirror and boot into the Arch live environment
  7. Follow the Arch installation guide: https://wiki.archlinux.org/title/Installation_guide

REQUIREMENTS:
  - Wired Ethernet connection (Wi-Fi is not supported during netboot)
  - UEFI boot mode (recommended) or Legacy BIOS
  - At least 2 GB RAM on the target machine

NOTES:
  - This always boots the LATEST Arch Linux release — no need to re-flash
  - The iPXE image is ~1 MB; the rest of the USB is free for your files
  - For the full install script, see: deploy/bare-metal/cli/01-install-os.sh

REFERENCES:
  - https://archlinux.org/releng/netboot/
  - https://wiki.archlinux.org/title/Netboot
  - https://wiki.archlinux.org/title/Installation_guide

================================================================================
README
    print_success "Created README.txt"

    # ── Step 7: Unmount and sync ─────────────────────────────────────────────
    print_step "Syncing and unmounting..."
    sync
    umount "${WORK_DIR}/mnt"

    print_success "Netboot USB created successfully!"
}

################################################################################
# Summary
################################################################################

print_summary_iso() {
    print_header "USB Boot Drive Ready! (ISO Mode)"
    cat << EOF

  $(echo -e "${GREEN}")Arch Linux boot USB created successfully!$(echo -e "${NC}")

  Device:     $DISK
  Mode:       ISO (full live environment)
  ISO:        $(basename "$ISO_PATH")

  How to use:
    1. Plug the USB into your target machine
    2. Enter BIOS/UEFI boot menu (F12 / F2 / DEL)
    3. Select the USB drive
    4. Arch Linux live environment will boot
    5. Run the install script:
       curl -sL <your-repo-url>/01-install-os.sh | bash

  To re-flash with a newer ISO, just run this script again.

EOF
}

print_summary_netboot() {
    print_header "USB Boot Drive Ready! (Netboot Mode)"
    cat << EOF

  $(echo -e "${GREEN}")Arch Linux netboot USB created successfully!$(echo -e "${NC}")

  Device:     $DISK
  Mode:       Netboot (iPXE → always latest Arch)
  EFI image:  EFI/boot/bootx64.efi (UEFI)
  BIOS image: arch/netboot/ipxe-arch.lkrn (Legacy)

  How to use:
    1. Connect target machine to wired Ethernet
    2. Plug in this USB drive
    3. Enter BIOS/UEFI boot menu (F12 / F2 / DEL)
    4. Disable Secure Boot if needed
    5. Select the USB drive → iPXE starts automatically
    6. Choose a mirror from the netboot menu
    7. Arch Linux live environment boots from the network
    8. Run the install script:
       curl -sL <your-repo-url>/01-install-os.sh | bash

  $(echo -e "${CYAN}")★ This USB NEVER needs re-flashing — it always boots the latest Arch!$(echo -e "${NC}")

  References:
    https://archlinux.org/releng/netboot/
    https://wiki.archlinux.org/title/Netboot

EOF
}

################################################################################
# Argument Parsing
################################################################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --iso)       MODE="iso";                       shift   ;;
        --netboot)   MODE="netboot";                   shift   ;;
        --disk)      DISK="$2";                        shift 2 ;;
        --iso-file)  ISO_PATH="$2"; SKIP_DOWNLOAD=true; shift 2 ;;
        --help)      usage ;;
        *)           print_error "Unknown option: $1"; usage ;;
    esac
done

################################################################################
# Main
################################################################################

main() {
    print_header "Arch Linux Boot USB Creator"
    echo ""
    echo "  Creates a bootable USB drive for bare-metal Arch Linux installation."
    echo "  Supports ISO (offline) and Netboot (always latest, needs Ethernet)."
    echo ""

    # ── Pre-flight ────────────────────────────────────────────────────────────
    check_root

    # ── Mode selection ────────────────────────────────────────────────────────
    if [[ -z "$MODE" ]]; then
        select_mode
    fi
    print_info "Mode: $MODE"

    check_dependencies

    # ── Disk selection ────────────────────────────────────────────────────────
    if [[ -n "$DISK" ]]; then
        validate_disk
        print_info "Target device: $DISK"

        # Still ask for confirmation if not already done
        local disk_model disk_size
        disk_model="$(lsblk -d -n -o MODEL "$DISK" 2>/dev/null | xargs)"
        disk_size="$(lsblk -d -n -o SIZE "$DISK" 2>/dev/null | xargs)"

        print_warning "ALL DATA ON $DISK ($disk_size, $disk_model) WILL BE DESTROYED!"
        read -rp "  Type 'YES' to confirm: " confirm
        if [[ "$confirm" != "YES" ]]; then
            print_error "Aborted"
            exit 1
        fi
    else
        select_disk
    fi

    # ── Execute ───────────────────────────────────────────────────────────────
    case "$MODE" in
        iso)
            download_iso
            write_iso_to_usb
            print_summary_iso
            ;;
        netboot)
            create_netboot_usb
            print_summary_netboot
            ;;
    esac

    print_success "Done! You can safely remove the USB drive."
}

main
