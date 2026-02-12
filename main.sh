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

    # Setup Autorun (Udev + Systemd)
    log_info "Configuring systemd and udev rules..."

    # Define paths
    UDEV_RULE_FILE="/etc/udev/rules.d/99-electrum-usb.rules"
    SERVICE_ADD_FILE="/etc/systemd/system/usb-app-add.service"
    SERVICE_REMOVE_FILE="/etc/systemd/system/usb-app-remove.service"
    SCRIPT_ADD_FILE="/usr/local/bin/usb-app-add.sh"
    SCRIPT_REMOVE_FILE="/usr/local/bin/usb-app-remove.sh"
    
    # Determine the target user (the one running sudo)
    TARGET_USER="${SUDO_USER:-$(whoami)}"
    log_info "Target user for desktop entry: $TARGET_USER"

    # 1. Create Udev Rule
    log_info "Creating udev rule: $UDEV_RULE_FILE"
    cat <<EOF > "$UDEV_RULE_FILE"
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-app-add.service"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-app-remove.service"
EOF

    # 2. Create Systemd Service (Add)
    log_info "Creating service: $SERVICE_ADD_FILE"
    cat <<EOF > "$SERVICE_ADD_FILE"
[Unit]
Description=Create desktop entry for USB AppImage

[Service]
Type=oneshot
ExecStart=$SCRIPT_ADD_FILE
EOF

    # 3. Create Systemd Service (Remove)
    log_info "Creating service: $SERVICE_REMOVE_FILE"
    cat <<EOF > "$SERVICE_REMOVE_FILE"
[Unit]
Description=Remove desktop entry for USB AppImage

[Service]
Type=oneshot
ExecStart=$SCRIPT_REMOVE_FILE
EOF

    # 4. Create Script (Add)
    log_info "Creating script: $SCRIPT_ADD_FILE"
    cat <<EOF > "$SCRIPT_ADD_FILE"
#!/bin/bash

USER_NAME="$TARGET_USER"
APP_DIR="/home/\$USER_NAME/.local/share/applications"
DESKTOP_FILE="\$APP_DIR/usb-app.desktop"

# Wait for mount point to appear (max 10 seconds)
# systemd triggers this immediately on device insertion, but auto-mount takes a moment
for i in {1..10}; do
    # 1. lsblk -n -o MOUNTPOINT,TRAN: Lists mountpoints and transport
    # 2. grep ' usb$': Filters lines ending in ' usb' (USB transport)
    # 3. awk '\$1 ~ /^\// {print \$1}': Prints first column ONLY if it starts with / (absolute path)
    MOUNT=\$(lsblk -n -o MOUNTPOINT,TRAN | grep ' usb$' | awk '\$1 ~ /^\// {print \$1}' | head -n1)

    if [ -n "\$MOUNT" ]; then
        break
    fi
    sleep 1
done

if [ -n "\$MOUNT" ]; then
    APP=\$(find "\$MOUNT" -maxdepth 2 -name "*.AppImage" | head -n1)
    if [ -n "\$APP" ]; then
        echo "[Desktop Entry]
Name=USB App
Exec=\$APP
Icon=application-x-executable
Type=Application
Terminal=false" > "\$DESKTOP_FILE"

        chmod +x "\$DESKTOP_FILE"
        chown "\$USER_NAME:\$(id -g \$USER_NAME)" "\$DESKTOP_FILE"
    else
        echo "No AppImage found in \$MOUNT"
    fi
else
    echo "No USB mount point found after waiting."
fi
EOF

    # 5. Create Script (Remove)
    log_info "Creating script: $SCRIPT_REMOVE_FILE"
    cat <<EOF > "$SCRIPT_REMOVE_FILE"
#!/bin/bash

USER_NAME="$TARGET_USER"
rm -f "/home/\$USER_NAME/.local/share/applications/usb-app.desktop"
EOF

# 6. Set Permissions & Reload
log_info "Setting permissions and reloading daemons..."
chmod +x "$SCRIPT_ADD_FILE" "$SCRIPT_REMOVE_FILE"

systemctl daemon-reload
udevadm control --reload
udevadm trigger

log_info "Autorun configuration complete."

log_info "Unmounting $MOUNT_POINT..."
umount "$MOUNT_POINT" || log_warn "Failed to unmount. Please unmount manually."
rmdir "$MOUNT_POINT" 2>/dev/null || true # Cleanup mount point if empty

log_info "Installation Complete!"
echo "Please re-plug your USB drive to trigger the autorun."