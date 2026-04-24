#!/bin/bash
################################################################################
# Arch Linux LUKS + TPM2 Installation Script — Dual-Boot Desktop
# Target: Dell G5 5000 (i5-10400 Comet Lake, Intel UHD 630, 2 TB NVMe)
#
# Layout:  EFI (1G) + LUKS2 Arch root (~1300 GiB) + Windows 11 (rest ~560 GiB)
# Unlock:  Slot 0 = recovery passphrase, Slot 1 = TPM2 auto-unlock
# Boot:    systemd-boot (auto-detects Windows after Windows install)
# Network: DHCP (default) or static IP
#
# Date: February 25, 2026
################################################################################

set -euo pipefail

################################################################################
# Constants
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/arch-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

################################################################################
# Defaults
################################################################################

DEFAULT_HOSTNAME="dell-desktop"
DEFAULT_USERNAME="ivan"
DEFAULT_TIMEZONE="Europe/Amsterdam"
DEFAULT_DNS="192.168.200.254"
DEFAULT_GATEWAY="192.168.200.254"
DEFAULT_CIDR="24"

# Dual-boot partition sizes (GiB — sgdisk native unit)
DEFAULT_ARCH_SIZE_GIB=500

# Populated by CLI flags or prompts
DISK=""
HOSTNAME=""
USERNAME="$DEFAULT_USERNAME"
LUKS_PASS=""
TIMEZONE="$DEFAULT_TIMEZONE"
ARCH_SIZE_GIB="$DEFAULT_ARCH_SIZE_GIB"

# Network
NETWORK_MODE="dhcp"           # "dhcp" or "static"
IP_ADDRESS=""
GATEWAY="$DEFAULT_GATEWAY"
DNS="$DEFAULT_DNS"
CIDR="$DEFAULT_CIDR"

NON_INTERACTIVE=false
SKIP_TPM=false
SINGLE_BOOT=false             # set to true to skip Windows partition

# Set during partitioning
ESP=""
LUKS_PART=""
WIN_PART=""

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

usage() {
    cat << 'EOF'
Usage: 01-install-os-dell-desktop.sh [OPTIONS]

Installs Arch Linux with LUKS2 encryption and optional TPM2 auto-unlock on
a Dell G5 5000 desktop, with a dual-boot partition layout for Windows 11.

REQUIRED:
    --disk DISK         Target disk (e.g., /dev/nvme0n1)
    --luks-pass PASS    LUKS recovery passphrase (min 12 chars)

OPTIONAL — identity:
    --hostname NAME     Hostname             (default: archlinux)
    --user NAME         Primary user account  (default: admin)

OPTIONAL — network:
    --dhcp              Use DHCP             (default)
    --static-ip IP      Use static IP — also requires --gateway
    --gateway IP        Gateway              (default: 192.168.1.1)
    --dns SERVERS       DNS, comma-sep       (default: 1.1.1.1)
    --cidr BITS         Subnet prefix        (default: 24)

OPTIONAL — partitioning:
    --arch-size GIB     Arch partition size in GiB  (default: 1300 ≈ 1.4 TB)
    --single-boot       Skip Windows partition (use entire disk for Arch)

OPTIONAL — misc:
    --timezone TZ       Timezone             (default: Europe/Amsterdam)
    --skip-tpm          Skip TPM2 enrollment (enroll manually later)
    --non-interactive   Skip all prompts     (requires --disk + --luks-pass)
    --help              Show this help

EXAMPLES:
    # Interactive — answers all prompts
    ./01-install-os-dell-desktop.sh

    # Non-interactive dual-boot with DHCP
    ./01-install-os-dell-desktop.sh --non-interactive \
        --disk /dev/nvme0n1 --luks-pass "MyRecoveryPass123!" \
        --hostname ivan-desktop --user ivan

    # Non-interactive with static IP
    ./01-install-os-dell-desktop.sh --non-interactive \
        --disk /dev/nvme0n1 --luks-pass "MyRecoveryPass123!" \
        --static-ip 192.168.1.100 --gateway 192.168.1.1

    # Single-boot (no Windows partition)
    ./01-install-os-dell-desktop.sh --single-boot --disk /dev/nvme0n1 \
        --luks-pass "MyRecoveryPass123!"
EOF
    exit 0
}

################################################################################
# Pre-flight Checks
################################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_uefi() {
    print_info "Checking UEFI boot mode..."
    if [[ -d /sys/firmware/efi/efivars ]]; then
        print_success "UEFI mode detected"
    else
        print_error "System is not booted in UEFI mode"
        exit 1
    fi
}

check_network() {
    print_info "Checking network connectivity..."
    if ping -c 3 -W 5 archlinux.org &>/dev/null; then
        print_success "Network OK"
    else
        print_error "No network. Configure network first (e.g., iwctl or dhcpcd)."
        exit 1
    fi
}

sync_time() {
    print_info "Synchronizing system clock..."
    timedatectl set-ntp true
    sleep 2
    print_success "Clock synced"
}

################################################################################
# Interactive Prompts
################################################################################

select_disk() {
    print_header "Select Target Disk"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -v loop
    echo ""

    local disks
    mapfile -t disks < <(lsblk -d -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}')

    if [[ ${#disks[@]} -eq 0 ]]; then
        print_error "No disks found"
        exit 1
    fi

    for i in "${!disks[@]}"; do
        local size model
        size="$(lsblk -d -n -o SIZE "${disks[$i]}")"
        model="$(lsblk -d -n -o MODEL "${disks[$i]}" 2>/dev/null || echo "unknown")"
        echo "  $((i+1))) ${disks[$i]}  ${size}  ${model}"
    done
    echo ""

    while true; do
        read -rp "Select disk number: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#disks[@]} )); then
            DISK="${disks[$((sel-1))]}"
            break
        fi
        print_error "Invalid selection"
    done

    print_warning "ALL DATA ON $DISK WILL BE DESTROYED!"
    read -rp "Type 'YES' to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        print_error "Aborted"
        exit 1
    fi
}

prompt_hostname() {
    while true; do
        read -rp "Enter hostname [$DEFAULT_HOSTNAME]: " input
        input="${input:-$DEFAULT_HOSTNAME}"
        if [[ "$input" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
            HOSTNAME="$input"
            break
        fi
        print_error "Invalid hostname — must start with alphanumeric, then alphanumeric/hyphens"
    done
}

prompt_username() {
    while true; do
        read -rp "Enter primary username [$DEFAULT_USERNAME]: " input
        input="${input:-$DEFAULT_USERNAME}"
        if [[ "$input" =~ ^[a-z][a-z0-9_-]*$ ]]; then
            USERNAME="$input"
            break
        fi
        print_error "Invalid username — lowercase, start with letter"
    done
}

prompt_luks_password() {
    while true; do
        read -rs -p "Enter LUKS recovery passphrase: " pass1; echo
        read -rs -p "Confirm passphrase: " pass2; echo

        if [[ "$pass1" != "$pass2" ]]; then
            print_error "Passphrases do not match"
            continue
        fi
        if [[ ${#pass1} -lt 12 ]]; then
            print_error "Passphrase must be at least 12 characters"
            continue
        fi

        LUKS_PASS="$pass1"
        break
    done
}

prompt_network_mode() {
    print_header "Network Configuration"
    echo ""
    echo "  1) DHCP   — automatic IP from router (recommended for desktop)"
    echo "  2) Static — fixed IP address"
    echo ""

    while true; do
        read -rp "Select network mode [1]: " sel
        sel="${sel:-1}"
        case "$sel" in
            1)
                NETWORK_MODE="dhcp"
                print_success "Network mode: DHCP"
                return
                ;;
            2)
                NETWORK_MODE="static"
                prompt_static_network
                return
                ;;
            *)
                print_error "Invalid selection"
                ;;
        esac
    done
}

prompt_static_network() {
    while true; do
        read -rp "Static IP (e.g., 192.168.1.100): " IP_ADDRESS
        if [[ "$IP_ADDRESS" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        print_error "Invalid IP format"
    done

    local auto_gw
    auto_gw="$(echo "$IP_ADDRESS" | sed 's/\.[0-9]*$/.1/')"

    read -rp "CIDR prefix [$DEFAULT_CIDR]: " input
    CIDR="${input:-$DEFAULT_CIDR}"

    read -rp "Gateway [$auto_gw]: " input
    GATEWAY="${input:-$auto_gw}"

    read -rp "DNS [$DEFAULT_DNS]: " input
    DNS="${input:-$DEFAULT_DNS}"
}

prompt_partition_layout() {
    if [[ "$SINGLE_BOOT" == "true" ]]; then
        return
    fi

    print_header "Partition Layout"
    echo ""
    echo "  Disk: $DISK"
    echo ""
    echo "  Default dual-boot layout on a 2 TB NVMe:"
    echo "    Partition 1:  EFI System    1 GiB     (FAT32, shared)"
    echo "    Partition 2:  Arch LUKS     ${ARCH_SIZE_GIB} GiB   (~1.4 TB)"
    echo "    Partition 3:  Windows 11    rest      (~560 GiB ≈ 600 GB)"
    echo ""

    while true; do
        read -rp "Arch partition size in GiB [$ARCH_SIZE_GIB]: " input
        input="${input:-$ARCH_SIZE_GIB}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 64 )); then
            ARCH_SIZE_GIB="$input"
            break
        fi
        print_error "Must be a number >= 64"
    done

    echo ""
    print_info "Layout confirmed: EFI (1G) + Arch (${ARCH_SIZE_GIB}G) + Windows (rest)"
}

################################################################################
# Disk Operations
################################################################################

cleanup_existing() {
    print_header "Cleaning Up Previous Installation"

    # Unmount everything under /mnt
    if mountpoint -q /mnt &>/dev/null; then
        print_info "Unmounting /mnt..."
        umount -R /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
    fi

    # Close any open LUKS container
    if [[ -e /dev/mapper/cryptroot ]]; then
        print_info "Closing existing LUKS container..."
        cryptsetup close cryptroot 2>/dev/null || true
    fi

    # Determine partition path for LUKS wipe
    local luks_part
    if [[ "$DISK" =~ nvme|mmcblk ]]; then
        luks_part="${DISK}p2"
    else
        luks_part="${DISK}2"
    fi

    if [[ -e "$luks_part" ]] && cryptsetup isLuks "$luks_part" 2>/dev/null; then
        print_info "Wiping LUKS signatures from $luks_part..."
        wipefs -a "$luks_part" 2>/dev/null || true
    fi

    print_success "Cleanup complete"
}

partition_disk() {
    print_header "Partitioning: $DISK"

    print_info "Wiping partition table..."
    wipefs -af "$DISK" 2>/dev/null || true
    sgdisk --zap-all "$DISK"
    sleep 1

    if [[ "$SINGLE_BOOT" == "true" ]]; then
        # Single-boot: EFI (1G) + LUKS (rest)
        print_info "Layout: EFI (1G) + Arch LUKS (rest of disk)"
        sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:"EFI"      "$DISK"
        sgdisk -n 2:0:0    -t 2:8309 -c 2:"ArchLUKS"  "$DISK"
    else
        # Dual-boot: EFI (1G) + Arch LUKS (sized) + Windows (rest)
        print_info "Layout: EFI (1G) + Arch LUKS (${ARCH_SIZE_GIB}G) + Windows (rest)"
        sgdisk -n 1:0:+1G                  -t 1:ef00 -c 1:"EFI"      "$DISK"
        sgdisk -n 2:0:+${ARCH_SIZE_GIB}G   -t 2:8309 -c 2:"ArchLUKS" "$DISK"
        sgdisk -n 3:0:0                    -t 3:0700 -c 3:"Windows"  "$DISK"
    fi

    sleep 2
    partprobe "$DISK"
    sleep 2
    udevadm settle

    # Resolve partition device paths
    if [[ "$DISK" =~ nvme|mmcblk ]]; then
        ESP="${DISK}p1"
        LUKS_PART="${DISK}p2"
        [[ "$SINGLE_BOOT" != "true" ]] && WIN_PART="${DISK}p3"
    else
        ESP="${DISK}1"
        LUKS_PART="${DISK}2"
        [[ "$SINGLE_BOOT" != "true" ]] && WIN_PART="${DISK}3"
    fi

    echo ""
    print_success "Partitions created:"
    print_info "  ESP:  $ESP  (1 GiB, EFI System)"
    print_info "  LUKS: $LUKS_PART  (${ARCH_SIZE_GIB} GiB, Linux LUKS)"
    if [[ "$SINGLE_BOOT" != "true" ]]; then
        print_info "  Win:  $WIN_PART  (rest of disk, Microsoft Basic Data)"
    fi
    echo ""
    lsblk "$DISK"
}

setup_luks() {
    print_header "LUKS2 Encryption"

    print_info "Formatting $LUKS_PART with LUKS2 (slot 0 = recovery passphrase)..."
    echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --pbkdf argon2id \
        --label cryptroot \
        "$LUKS_PART" -

    print_info "Opening LUKS container..."
    echo -n "$LUKS_PASS" | cryptsetup open "$LUKS_PART" cryptroot -

    print_success "LUKS container open at /dev/mapper/cryptroot"
}

format_and_mount() {
    print_header "Formatting & Mounting"

    print_info "Formatting root (ext4 on /dev/mapper/cryptroot)..."
    mkfs.ext4 -L root /dev/mapper/cryptroot

    print_info "Formatting EFI (FAT32 on $ESP)..."
    mkfs.fat -F32 "$ESP"

    print_info "Mounting root -> /mnt..."
    mount /dev/mapper/cryptroot /mnt

    print_info "Mounting EFI -> /mnt/efi..."
    mkdir -p /mnt/efi
    mount "$ESP" /mnt/efi

    print_success "Filesystems mounted"
    df -h /mnt /mnt/efi
}

################################################################################
# System Installation
################################################################################

refresh_keyring() {
    print_header "Refreshing Pacman Keyring"
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Sy --noconfirm archlinux-keyring
    print_success "Keyring up to date"
}

install_base() {
    print_header "Installing Base System"

    pacstrap -K /mnt \
        base linux linux-firmware intel-ucode \
        vim nano \
        networkmanager openssh sudo \
        cryptsetup tpm2-tss \
        git curl wget \
        man-db man-pages bash-completion htop \
        efibootmgr dosfstools \
        ntfs-3g \
        zram-generator

    print_success "Base system installed"
}

generate_fstab() {
    print_header "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab

    print_info "fstab contents:"
    cat /mnt/etc/fstab
    print_success "fstab generated"
}

configure_system() {
    print_header "System Configuration"

    print_info "Timezone: $TIMEZONE"
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot /mnt hwclock --systohc

    print_info "Locale: en_US.UTF-8"
    echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

    # Required by sd-vconsole mkinitcpio hook
    print_info "Setting console keymap..."
    echo "KEYMAP=us" > /mnt/etc/vconsole.conf

    print_info "Hostname: $HOSTNAME"
    echo "$HOSTNAME" > /mnt/etc/hostname

    cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

    print_success "System configured"
}

configure_network() {
    print_header "Network Configuration"

    arch-chroot /mnt systemctl enable NetworkManager

    mkdir -p /mnt/etc/NetworkManager/system-connections

    if [[ "$NETWORK_MODE" == "dhcp" ]]; then
        cat > /mnt/etc/NetworkManager/system-connections/ethernet.nmconnection << EOF
[connection]
id=ethernet
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=disabled
EOF
        chmod 600 /mnt/etc/NetworkManager/system-connections/ethernet.nmconnection
        print_success "Network: DHCP (auto)"
    else
        local dns_formatted
        dns_formatted="$(echo "$DNS" | tr ',' ';');"

        cat > /mnt/etc/NetworkManager/system-connections/ethernet.nmconnection << EOF
[connection]
id=ethernet
type=ethernet
autoconnect=true

[ipv4]
method=manual
address1=${IP_ADDRESS}/${CIDR},${GATEWAY}
dns=${dns_formatted}

[ipv6]
method=disabled
EOF
        chmod 600 /mnt/etc/NetworkManager/system-connections/ethernet.nmconnection
        print_success "Static IP: ${IP_ADDRESS}/${CIDR} via ${GATEWAY}"
    fi
}

configure_zram() {
    print_header "Swap (zram)"

    # zram-generator: compressed RAM swap — better than no swap on a desktop
    mkdir -p /mnt/etc/systemd
    cat > /mnt/etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

    print_success "zram swap configured (50% of RAM, zstd compression)"
}

configure_initramfs() {
    print_header "Initramfs (mkinitcpio)"

    # Use systemd-based hooks: sd-encrypt handles LUKS + TPM2 natively
    # via systemd-cryptenroll (no AUR packages needed)
    print_info "Setting HOOKS for systemd-based LUKS + TPM2 unlock..."
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
        /mnt/etc/mkinitcpio.conf

    # Dell G5 5000: Intel i5-10400 (Comet Lake) + Intel UHD 630 iGPU
    # + Intel I219-LM/V Ethernet — load early for KMS and network
    sed -i 's/^MODULES=.*/MODULES=(i915 e1000e)/' /mnt/etc/mkinitcpio.conf

    print_info "Regenerating initramfs..."
    arch-chroot /mnt mkinitcpio -P

    print_success "Initramfs built"
}

install_bootloader() {
    print_header "Bootloader (systemd-boot)"

    print_info "Installing systemd-boot to /efi..."
    arch-chroot /mnt bootctl install

    local luks_uuid
    luks_uuid="$(blkid -s UUID -o value "$LUKS_PART")"

    print_info "LUKS UUID: $luks_uuid"

    # Loader configuration — auto-entries discovers Windows after install
    cat > /mnt/efi/loader/loader.conf << 'EOF'
default arch.conf
timeout 5
console-mode max
editor  no
auto-entries  1
auto-firmware 1
EOF

    # Arch Linux boot entry — rd.luks.name for sd-encrypt hook
    cat > /mnt/efi/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${luks_uuid}=cryptroot root=/dev/mapper/cryptroot rw
EOF

    # systemd-boot reads kernels from /efi but Arch installs them to /boot.
    # Copy kernel + initramfs so bootctl finds them.
    print_info "Copying kernel & initramfs to /efi..."
    cp /mnt/boot/vmlinuz-linux       /mnt/efi/
    cp /mnt/boot/intel-ucode.img     /mnt/efi/
    cp /mnt/boot/initramfs-linux.img /mnt/efi/

    # Pacman hook: auto-copy kernel files to ESP after upgrades
    mkdir -p /mnt/etc/pacman.d/hooks
    cat > /mnt/etc/pacman.d/hooks/95-systemd-boot.hook << 'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz
Target = boot/intel-ucode.img

[Action]
Description = Copying kernel & initramfs to EFI partition...
When = PostTransaction
Exec = /bin/sh -c 'cp /boot/vmlinuz-linux /efi/ && cp /boot/intel-ucode.img /efi/ && cp /boot/initramfs-linux.img /efi/'
EOF

    print_success "systemd-boot installed (timeout 5s, auto-entries on)"
}

enroll_tpm2() {
    print_header "TPM2 Auto-Unlock (systemd-cryptenroll)"

    if [[ "$SKIP_TPM" == "true" ]]; then
        print_warning "TPM enrollment skipped (--skip-tpm). Enroll manually later:"
        print_info "  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+1+7 $LUKS_PART"
        return
    fi

    # Check if a TPM2 device is available
    if [[ ! -e /dev/tpm0 ]] && [[ ! -e /dev/tpmrm0 ]]; then
        print_warning "No TPM2 device detected — skipping enrollment"
        print_info "You can enroll later after booting into the installed system:"
        print_info "  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+1+7 $LUKS_PART"
        print_info "  mkinitcpio -P"
        return
    fi

    print_info "Enrolling TPM2 to LUKS (PCRs 0+1+7) via systemd-cryptenroll..."
    echo -n "$LUKS_PASS" | systemd-cryptenroll "$LUKS_PART" \
        --tpm2-device=auto \
        --tpm2-pcrs=0+1+7 \
        --unlock-key-file=/dev/stdin

    print_success "TPM2 enrolled — drive will auto-unlock on normal boot"
    print_info "Slot 0 = recovery passphrase (manual fallback)"
    print_info "Slot 1+ = TPM2 auto-unlock (systemd-cryptenroll)"
}

configure_users() {
    print_header "Users & Sudo"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        print_warning "Non-interactive: root & $USERNAME passwords set to LUKS passphrase"
        echo "root:${LUKS_PASS}" | arch-chroot /mnt chpasswd
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
        echo "${USERNAME}:${LUKS_PASS}" | arch-chroot /mnt chpasswd
        print_warning "Change these passwords after first login!"
    else
        print_info "Set root password:"
        arch-chroot /mnt passwd

        print_info "Creating user '$USERNAME'..."
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
        print_info "Set $USERNAME password:"
        arch-chroot /mnt passwd "$USERNAME"
    fi

    # Enable sudo for wheel
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers

    print_success "Users configured (root + $USERNAME)"
}

enable_services() {
    print_header "Enabling Services"

    arch-chroot /mnt systemctl enable NetworkManager
    arch-chroot /mnt systemctl enable sshd
    arch-chroot /mnt systemctl enable systemd-timesyncd

    # Harden SSH
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/'               /mnt/etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /mnt/etc/ssh/sshd_config

    print_success "NetworkManager + SSHD + timesyncd enabled"
}

################################################################################
# Summary
################################################################################

print_summary() {
    print_header "Installation Complete"

    local net_display
    if [[ "$NETWORK_MODE" == "dhcp" ]]; then
        net_display="DHCP (automatic)"
    else
        net_display="${IP_ADDRESS}/${CIDR} via ${GATEWAY}"
    fi

    cat << EOF

$(echo -e "${GREEN}")Installation completed successfully!$(echo -e "${NC}")

  Hostname:   ${HOSTNAME}
  User:       ${USERNAME}
  Network:    ${net_display}
  DNS:        ${DNS}
  Timezone:   ${TIMEZONE}

  Disk:       ${DISK}
  ESP:        ${ESP} (1 GiB, FAT32, mounted /efi)
  LUKS:       ${LUKS_PART} (LUKS2, ext4 on /dev/mapper/cryptroot -> /)
EOF

    if [[ "$SINGLE_BOOT" != "true" ]]; then
        cat << EOF
  Windows:    ${WIN_PART} (unformatted — ready for Windows 11 installer)
EOF
    fi

    cat << EOF

  Unlock:
    Slot 0:   Recovery passphrase (manual)
    Slot 1+:  TPM2 auto-unlock (systemd-cryptenroll)

  Bootloader: systemd-boot (timeout 5s, auto-entries enabled)

  Swap:       zram (50% of RAM, zstd)

Next steps:
  1. Reboot into Arch Linux
  2. TPM2 should auto-unlock the disk (or enter passphrase as fallback)
  3. Login as '${USERNAME}', verify network: ip a && ping 1.1.1.1
  4. Run 02-hyprland-env.sh to install Hyprland desktop environment
EOF

    if [[ "$SINGLE_BOOT" != "true" ]]; then
        cat << EOF

Windows 11 Dual-Boot Setup:
  5. Boot from a Windows 11 USB installer
  6. Choose "Custom install" -> select the ~560 GiB unformatted partition
     (DO NOT format or delete other partitions — EFI is shared!)
  7. After Windows installs, it will add its boot entry to the shared EFI
  8. Windows will set itself as default boot — change back in BIOS:
       BIOS -> Boot -> set "Linux Boot Manager" as first priority
     Or from Arch live USB:
       efibootmgr -o <linux-entry>,<windows-entry>
  9. systemd-boot will auto-detect Windows (auto-entries is enabled)
     You will see both "Arch Linux" and "Windows Boot Manager" at boot

EOF
    fi

    cat << EOF
TPM re-enrollment (after BIOS/firmware updates):
    systemd-cryptenroll --wipe-slot=tpm2 ${LUKS_PART}
    systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+1+7 ${LUKS_PART}
    mkinitcpio -P

Mount Windows partition from Arch (after Windows is installed):
    sudo mkdir -p /mnt/windows
    sudo mount -t ntfs3 ${WIN_PART:-/dev/nvme0n1p3} /mnt/windows

Installation log: ${LOG_FILE}

EOF
}

################################################################################
# Argument Parsing
################################################################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --disk)            DISK="$2";              shift 2 ;;
        --hostname)        HOSTNAME="$2";          shift 2 ;;
        --user)            USERNAME="$2";           shift 2 ;;
        --luks-pass)       LUKS_PASS="$2";         shift 2 ;;
        --dhcp)            NETWORK_MODE="dhcp";    shift   ;;
        --static-ip)       NETWORK_MODE="static"; IP_ADDRESS="$2"; shift 2 ;;
        --gateway)         GATEWAY="$2";           shift 2 ;;
        --dns)             DNS="$2";               shift 2 ;;
        --cidr)            CIDR="$2";              shift 2 ;;
        --timezone)        TIMEZONE="$2";          shift 2 ;;
        --arch-size)       ARCH_SIZE_GIB="$2";     shift 2 ;;
        --single-boot)     SINGLE_BOOT=true;       shift   ;;
        --skip-tpm)        SKIP_TPM=true;          shift   ;;
        --non-interactive) NON_INTERACTIVE=true;   shift   ;;
        --help)            usage ;;
        *)                 print_error "Unknown option: $1"; usage ;;
    esac
done

################################################################################
# Main
################################################################################

main() {
    print_header "Arch Linux LUKS+TPM2 Desktop Installer (Dell G5 5000)"
    echo ""
    print_info "Target: Dell G5 5000 — i5-10400 (Comet Lake), Intel UHD 630"
    if [[ "$SINGLE_BOOT" == "true" ]]; then
        print_info "Mode:   Single-boot (Arch only)"
    else
        print_info "Mode:   Dual-boot (Arch Linux + Windows 11)"
    fi
    echo ""

    # -- Pre-flight ---------------------------------------------------------
    check_root
    check_uefi
    check_network
    sync_time

    # -- Validate non-interactive requirements ------------------------------
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        local missing=()
        [[ -z "$DISK" ]]     && missing+=("--disk")
        [[ -z "$LUKS_PASS" ]] && missing+=("--luks-pass")
        if [[ "$NETWORK_MODE" == "static" && -z "$IP_ADDRESS" ]]; then
            missing+=("--static-ip")
        fi
        if [[ ${#missing[@]} -gt 0 ]]; then
            print_error "Non-interactive mode requires: ${missing[*]}"
            exit 1
        fi
        # Apply defaults for non-interactive
        [[ -z "$HOSTNAME" ]] && HOSTNAME="$DEFAULT_HOSTNAME"
    fi

    # -- Interactive prompts for anything still missing ---------------------
    if [[ -z "$DISK" ]]; then
        select_disk
    fi

    if [[ -z "$HOSTNAME" ]]; then
        prompt_hostname
    fi

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        prompt_username
        prompt_network_mode
        prompt_partition_layout
    fi

    if [[ -z "$LUKS_PASS" ]]; then
        prompt_luks_password
    fi

    # -- Confirmation -------------------------------------------------------
    print_header "Configuration Summary"
    echo "  Hostname:   $HOSTNAME"
    echo "  User:       $USERNAME"
    if [[ "$NETWORK_MODE" == "dhcp" ]]; then
        echo "  Network:    DHCP"
    else
        echo "  Network:    Static ${IP_ADDRESS}/${CIDR} via ${GATEWAY}"
    fi
    echo "  DNS:        $DNS"
    echo "  Disk:       $DISK"
    if [[ "$SINGLE_BOOT" == "true" ]]; then
        echo "  Layout:     EFI (1G) + Arch LUKS (rest)"
    else
        echo "  Layout:     EFI (1G) + Arch LUKS (${ARCH_SIZE_GIB}G) + Windows (rest)"
    fi
    echo "  Timezone:   $TIMEZONE"
    echo "  TPM enroll: $(if [[ "$SKIP_TPM" == "true" ]]; then echo "skip"; else echo "yes"; fi)"
    echo ""

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Proceed? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            print_error "Aborted"
            exit 1
        fi
    else
        print_info "Non-interactive — proceeding"
    fi

    # -- Install ------------------------------------------------------------
    cleanup_existing
    partition_disk
    setup_luks
    format_and_mount
    refresh_keyring
    install_base
    generate_fstab
    configure_system
    configure_network
    configure_zram
    configure_initramfs
    install_bootloader
    enroll_tpm2
    configure_users
    enable_services

    # -- Cleanup ------------------------------------------------------------
    print_info "Unmounting filesystems..."
    umount -R /mnt

    print_info "Closing LUKS container..."
    cryptsetup close cryptroot

    # -- Done ---------------------------------------------------------------
    print_summary
}

main
