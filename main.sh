#!/bin/bash
# ==============================================================================
# Description: Automates the process of downloading the Electrum AppImage,
#              installing it to a USB drive, and configuring an autorun mechanism.
# Author:      fiandev
# Date:        $(date +%Y-%m-%d)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# CONSTANTS & CONFIGURATION
# ==============================================================================
readonly ELECTRUM_URL_BASE="https://electrum.org/#download"
readonly TEMP_DIR="/tmp/electrum_installer"
readonly UDEV_RULES_DIR="/etc/udev/rules.d"
readonly SYSTEM_AUTORUN_DIR="/usr/local/bin"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m' # No Color

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges. Please run with sudo."
        exit 1
    fi
}

cleanup() {
    if [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

check_root

echo "========================================================"
echo "          Electrum USB Installer & Autorun Setup        "
echo "========================================================"

# Device Selection
log_info "Scanning for removable storage devices..."
mkdir -p "${TEMP_DIR}"

# Get device list in key-value pairs to handle spaces in model names safely
mapfile -t devices_raw < <(lsblk -P -o NAME,MODEL,SIZE,TRAN,TYPE,MOUNTPOINT)

if [[ ${#devices_raw[@]} -eq 0 ]]; then
    log_error "No storage devices found."
    exit 1
fi

# Build table data
table_data="NAME|MODEL|SIZE|TYPE|MOUNTPOINT\n"
found_candidates=false

for line in "${devices_raw[@]}"; do
    eval "$line" # Parsing NAME="...", MODEL="..."
    
    # Filter logic: Show if transport is usb OR type is disk (excluding loop/ram)
    if [[ "$TRAN" == "usb" ]] || [[ "$TYPE" == "disk" ]]; then
        # Skip loop devices explicitly just in case
        if [[ "$TYPE" == "loop" ]]; then continue; fi
        
        found_candidates=true
        table_data+="${NAME}|${MODEL}|${SIZE}|${TYPE}|${MOUNTPOINT}\n"
    fi
done

if [[ "$found_candidates" == "false" ]]; then
    log_warn "No USB devices detected via transport type. Showing all disks..."
    table_data="NAME|MODEL|SIZE|TYPE|MOUNTPOINT\n"
    for line in "${devices_raw[@]}"; do
        eval "$line"
        if [[ "$TYPE" == "disk" ]]; then
            table_data+="${NAME}|${MODEL}|${SIZE}|${TYPE}|${MOUNTPOINT}\n"
        fi
    done
fi

echo -e "\nAvailable Devices:"
echo "-------------------------------------------------------------------------------"
echo -e "$table_data" | column -t -s '|'
echo "-------------------------------------------------------------------------------"

read -p "Enter the device name to use (e.g., sdb): " DEVICE_NAME

# Sanitize input
DEVICE_NAME=$(echo "$DEVICE_NAME" | tr -d '[:space:]')
DEVICE_PATH="/dev/${DEVICE_NAME}"

if [[ ! -b "$DEVICE_PATH" ]]; then
    log_error "Device $DEVICE_PATH does not exist."
    exit 1
fi

# Confirmation
log_warn "You selected: $DEVICE_PATH"
log_warn "WARNING: Ensure this is the correct device."
read -p "Continue? (y/N): " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    log_info "Operation cancelled by user."
    exit 0
fi

# Mount Point Handling
PARTITION="${DEVICE_PATH}1"

if [[ ! -b "$PARTITION" ]]; then
    log_error "Partition $PARTITION not found."
    exit 1
fi

MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "$PARTITION")

    if [[ -z "$MOUNT_POINT" ]]; then
        MOUNT_POINT="/mnt/usb_${DEVICE_NAME}"
        log_info "Device not mounted. Mounting $PARTITION to $MOUNT_POINT..."
        mkdir -p "$MOUNT_POINT"
        
        # Detect filesystem type to apply correct ownership
        FSTYPE=$(lsblk -no FSTYPE "$PARTITION")
        MOUNT_OPTIONS=""
        
        if [[ -n "${SUDO_USER:-}" ]]; then
            SUDO_UID=$(id -u "$SUDO_USER")
            SUDO_GID=$(id -g "$SUDO_USER")
            if [[ "$FSTYPE" =~ ^(vfat|exfat|ntfs)$ ]]; then
                MOUNT_OPTIONS="-o uid=$SUDO_UID,gid=$SUDO_GID"
            fi
        fi

        mount $MOUNT_OPTIONS "$PARTITION" "$MOUNT_POINT" || { log_error "Failed to mount $PARTITION"; exit 1; }
        
        # For ext4/xfs/btrfs, change ownership after mount
        if [[ -n "${SUDO_USER:-}" ]]; then
             if [[ ! "$FSTYPE" =~ ^(vfat|exfat|ntfs)$ ]]; then
                 chown "$SUDO_UID:$SUDO_GID" "$MOUNT_POINT"
             fi
        fi
    else
    log_info "Device already mounted at: $MOUNT_POINT"
fi

# Download Electrum
log_info "Fetching latest Electrum version URL..."

DESTINATION_DIR="${MOUNT_POINT}/electrum"
mkdir -p "$DESTINATION_DIR"

# Check for existing AppImage
EXISTING_APPIMAGE=$(find "$DESTINATION_DIR" -maxdepth 1 -name "*.AppImage" | head -n 1)

if [[ -n "$EXISTING_APPIMAGE" ]]; then
    FILENAME=$(basename "$EXISTING_APPIMAGE")
    DESTINATION_FILE="$EXISTING_APPIMAGE"
    log_info "Found existing AppImage: $FILENAME. Skipping download."
else
    DOWNLOAD_LINK=$(curl -s "$ELECTRUM_URL_BASE" | grep -o 'https://download.electrum.org/.*\.AppImage' | grep -v "debug" | head -n 1)

    if [[ -z "$DOWNLOAD_LINK" ]]; then
        log_error "Could not determine the latest Electrum download URL."
        exit 1
    fi
    
    FILENAME=$(basename "$DOWNLOAD_LINK")
    DESTINATION_FILE="${DESTINATION_DIR}/${FILENAME}"
    
    log_info "Target file: $FILENAME"
    log_info "Download Source: $DOWNLOAD_LINK"

    log_info "Downloading..."
    if ! curl -L "$DOWNLOAD_LINK" -o "$DESTINATION_FILE" --progress-bar; then
        log_error "Download failed."
        exit 1
    fi
fi

chmod +x "$DESTINATION_FILE"
log_info "Electrum AppImage ready at: $DESTINATION_FILE"

# Create .desktop file for portable launching
DESKTOP_FILE="${DESTINATION_DIR}/electrum.desktop"
cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=Electrum Wallet (Portable)
Comment=Lightweight Bitcoin Wallet
Exec=bash -c '"\$(dirname "\$1")"/run_electrum.sh' dummy %k
Icon=utilities-terminal
Type=Application
Terminal=false
Categories=Finance;Network;
EOF
chmod +x "$DESKTOP_FILE"
log_info "Created portable .desktop file: $DESKTOP_FILE"

# Create Launch Script on USB
USB_RUN_SCRIPT="${DESTINATION_DIR}/run_electrum.sh"

cat <<'EOF' > "$USB_RUN_SCRIPT"
#!/bin/bash
DIR="$(dirname "$(realpath "$0")")"
APPIMAGE="$(find "$DIR" -name "*.AppImage" | head -n 1)"

if [[ -f "$APPIMAGE" ]]; then
    echo "Launching Electrum..."
    "$APPIMAGE" &
else
    echo "Electrum AppImage not found in $DIR"
    read -p "Press Enter to exit..."
fi
EOF

chmod +x "$USB_RUN_SCRIPT"
log_info "Created launch script on USB: $USB_RUN_SCRIPT"

# Extract Vendor/Product ID for Udev
log_info "Extracting device identifiers for autorun configuration..."

eval "$(udevadm info -q property -n "$DEVICE_PATH" | grep -E 'ID_VENDOR_ID|ID_MODEL_ID')"
DEVICE_VID=${ID_VENDOR_ID:-}
DEVICE_PID=${ID_MODEL_ID:-}

if [[ -z "$DEVICE_VID" || -z "$DEVICE_PID" ]]; then
    log_warn "Udev properties missing. Attempting fallback using lsusb..."
    # This grep is weak, relies on name match
    USB_INFO=$(lsusb | grep -i "${DEVICE_NAME}" || true) 
    log_error "Could not automatically detect VID/PID. Autorun configuration skipped."
else
    log_info "Detected: VID=$DEVICE_VID PID=$DEVICE_PID"

    # Setup Autorun (Udev + Wrapper)
    # Using generalized filenames
    SYSTEM_AUTORUN_SCRIPT="/usr/local/bin/electrum-usb-launcher.sh"
    RULES_FILE="${UDEV_RULES_DIR}/99-electrum-usb.rules"

    log_info "Creating system autorun wrapper..."
    
    cat <<'EOF' > "$SYSTEM_AUTORUN_SCRIPT"
#!/bin/bash
# Wrapper script triggered by Udev for Electrum USB
# Logs to syslog via logger

log() {
    logger -t electro-usb "$1"
    echo "$1"
}

log "Device detected, script triggered."

# Wait for mount to settle
sleep 5

# Find the active X11/Wayland user
# This function tries multiple methods to find the user currently on the physical seat
get_active_user() {
    # Method 1: loginctl
    local user=$(loginctl list-sessions 2>/dev/null | grep 'active' | awk '{print $3}' | head -n 1)
    if [[ -n "$user" ]]; then
        echo "$user"
        return
    fi
    # Method 2: who (fallback)
    local user_who=$(who | grep '(:0)' | awk '{print $1}' | head -n 1)
    if [[ -n "$user_who" ]]; then
        echo "$user_who"
        return
    fi

    # Method 3: whoami
    local user_whoami=$(whoami) 
    if [[ -n "$user_whoami" ]]; then
        echo "$user_whoami"
        return
    fi
}

TARGET_USER=$(get_active_user)
echo "Active user: $TARGET_USER"
if [[ -z "$TARGET_USER" ]]; then
    log "No active GUI user found. Aborting."
    exit 0
fi

log "Active user detected: $TARGET_USER"

# Dynamic Mount Point Detection
CANDIDATE_SCRIPT=""

# Search common mount points for the user
for mount in $(find /media/$TARGET_USER /mnt /run/media/$TARGET_USER -maxdepth 4 -name "run_electrum.sh" 2>/dev/null); do
    CANDIDATE_SCRIPT="$mount"
    break
done

if [[ -z "$CANDIDATE_SCRIPT" || ! -f "$CANDIDATE_SCRIPT" ]]; then
    log "Could not find run_electrum.sh in standard locations. ($CANDIDATE_SCRIPT)"
    exit 0
fi

log "Found launch script at: $CANDIDATE_SCRIPT"

if [[ -z "$CANDIDATE_SCRIPT" || ! -f "$CANDIDATE_SCRIPT" ]]; then
    log "Could not find run_electrum.sh in standard locations. ($CANDIDATE_SCRIPT)"
    exit 0
fi

log "Found launch script at: $CANDIDATE_SCRIPT"

# --- DE Integration: Install .desktop file (Portable to System) ---
USB_MOUNT_DIR=$(dirname "$CANDIDATE_SCRIPT")
DESKTOP_DIR="/home/$TARGET_USER/.local/share/applications"
SYSTEM_DESKTOP_FILE="$DESKTOP_DIR/electrum-usb.desktop"

if [[ -d "$DESKTOP_DIR" ]]; then
    log "Installing desktop entry to $SYSTEM_DESKTOP_FILE..."
    
    # We create a new desktop file to ensure the Exec path is absolute and correct for this mount
    cat <<DE_EOF > "$SYSTEM_DESKTOP_FILE"
[Desktop Entry]
Name=Electrum Wallet (USB)
Comment=Portable Electrum Wallet from USB
Exec="$CANDIDATE_SCRIPT"
Icon=electrum
Type=Application
Terminal=false
Categories=Finance;Network;
DE_EOF

    # Fix ownership so it's user-writable/executable
    chown "$TARGET_USER:$(id -g $TARGET_USER)" "$SYSTEM_DESKTOP_FILE"
    chmod +x "$SYSTEM_DESKTOP_FILE"
    
    # Notify DE of updates (optional/if dbus is available)
    # update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
else
    log "User applications directory not found: $DESKTOP_DIR"
fi
# ------------------------------------------------------------------

export DISPLAY=:0
export XAUTHORITY="/home/$TARGET_USER/.Xauthority"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u $TARGET_USER)/bus"

log "Launching application..."

if [[ "$TARGET_USER" != "$(whoami)" ]]; then
    su - "$TARGET_USER" -c "\"$CANDIDATE_SCRIPT\"" &
else
    "$CANDIDATE_SCRIPT" &
fi
EOF

    chmod +x "$SYSTEM_AUTORUN_SCRIPT"

    log_info "Creating udev rule..."
    
    cat <<EOF > "$RULES_FILE"
SUBSYSTEM=="usb", ACTION=="add", ATTR{idVendor}=="$DEVICE_VID", ATTR{idProduct}=="$DEVICE_PID", RUN+=   "$SYSTEM_AUTORUN_SCRIPT"
EOF

    log_info "Reloading udev rules..."
    udevadm control --reload-rules
    udevadm trigger

    log_info "Autorun configured successfully."
    log_info "Wrapper: $SYSTEM_AUTORUN_SCRIPT"
    log_info "Rule: $RULES_FILE"
fi

log_info "Unmounting $MOUNT_POINT..."
umount "$MOUNT_POINT" || log_warn "Failed to unmount. Please unmount manually."
rmdir "$MOUNT_POINT" 2>/dev/null || true # Cleanup mount point if empty

log_info "Installation Complete!"
echo "Please re-plug your USB drive to trigger the autorun."