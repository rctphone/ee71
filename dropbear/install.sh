#!/usr/bin/env bash
set -euo pipefail

# install.sh — install dropbear from files/ to device in /system
# Structure: files/dropbearmulti-2014.66 (binary), files/dropbear (init.d script)
# Creates symbolic links for dropbear, dropbearkey, dropbearconvert, ssh, scp

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ADB_BIN="${ADB_BIN:-adb}"

log() { echo "[install] $*"; }
fail() { echo "[install][error] $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Not found: $1"
}

require_cmd "$ADB_BIN"

# Check for files in files/
FILES_DIR="$SCRIPT_DIR/files"
DROPBEAR_BINARY=""
INIT_SCRIPT="$FILES_DIR/dropbear"

# Find dropbearmulti binary with version
if [[ ! -d "$FILES_DIR" ]]; then
  fail "files/ directory not found next to install.sh."
fi

for f in "$FILES_DIR"/dropbearmulti-*; do
  if [[ -f "$f" ]]; then
    DROPBEAR_BINARY="$f"
    break
  fi
done

[[ -n "$DROPBEAR_BINARY" ]] || fail "dropbearmulti-* not found in files/"
[[ -f "$INIT_SCRIPT" ]] || fail "files/dropbear (init.d script) not found"

log "Found binary: $(basename "$DROPBEAR_BINARY")"
log "Found init.d script: $(basename "$INIT_SCRIPT")"

log "Starting adb server..."
"$ADB_BIN" start-server >/dev/null

log "Checking connected devices..."
DEVICES_COUNT=$("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {c++} END{print c+0}')
[[ "$DEVICES_COUNT" -ge 1 ]] || fail "No connected devices (adb devices)."

log "Creating target directories on device..."
"$ADB_BIN" shell 'mkdir -p /system/etc/init.d /system/etc/rc5.d /system/usr/bin /system/usr/sbin' >/dev/null

# Copy dropbearmulti binary
log "Copying dropbearmulti to /system/usr/sbin/..."
"$ADB_BIN" push "$DROPBEAR_BINARY" /system/usr/sbin/dropbearmulti >/dev/null

# Copy init.d script
log "Copying init.d script to /system/etc/init.d/..."
"$ADB_BIN" push "$INIT_SCRIPT" /system/etc/init.d/dropbear >/dev/null

# Create symbolic links
log "Creating symbolic links..."
"$ADB_BIN" shell '
  set -e
  cd /system/usr/sbin
  
  # Create links in /system/usr/sbin/
  ln -sf dropbearmulti dropbear 2>/dev/null || true
  ln -sf dropbearmulti dropbearkey 2>/dev/null || true
  ln -sf dropbearmulti dropbearconvert 2>/dev/null || true
  
  # Create links in /system/usr/bin/
  cd /system/usr/bin
  ln -sf /usr/sbin/dropbearmulti ssh 2>/dev/null || true
  ln -sf /usr/sbin/dropbearmulti scp 2>/dev/null || true
  
  # Create rc5.d -> init.d link
  cd /system/etc/rc5.d
  ln -sf ../init.d/dropbear S10dropbear 2>/dev/null || true
' >/dev/null || true

# Set permissions
log "Setting permissions..."
"$ADB_BIN" shell '
  set -e
  # Binary
  chmod 0755 /system/usr/sbin/dropbearmulti 2>/dev/null || true
  
  # Init.d script
  chmod 0755 /system/etc/init.d/dropbear 2>/dev/null || true
  
  # Symbolic links (link permissions are inherited from target file)
  # But check that they are created correctly
  for link in /system/usr/sbin/dropbear /system/usr/sbin/dropbearkey /system/usr/sbin/dropbearconvert \
              /system/usr/bin/ssh /system/usr/bin/scp /system/etc/rc5.d/S10dropbear; do
    if [ -L "$link" ]; then
      # Check that link is valid (not broken)
      test -e "$link" || echo "Warning: broken link: $link" >&2 || true
    fi
  done
  
  # Dropbear configs (if any)
  if [ -d /system/etc/dropbear ]; then
    chmod 0644 /system/etc/dropbear/* 2>/dev/null || true
  fi
' >/dev/null || true

# Set root password
log "Setting root password..."
ROOT_PASSWORD="oemlinux1"
"$ADB_BIN" shell "
  set -e
  # Chroot to /system and set root password
  # Try using chpasswd if available (most reliable method)
  if chroot /system sh -c 'echo root:${ROOT_PASSWORD} | chpasswd' 2>/dev/null; then
    echo 'Password set using chpasswd'
  # Try using passwd with input redirection (fallback)
  elif echo -e '${ROOT_PASSWORD}\\n${ROOT_PASSWORD}' | chroot /system passwd root 2>/dev/null; then
    echo 'Password set using passwd'
  else
    echo 'Warning: Could not set password automatically. Manual setting may be required.' >&2
    exit 1
  fi
" >/dev/null || log "Warning: Could not set root password. This may require manual intervention."

# Copy SSH public key (optional)
SSH_KEY_COPIED=false
SSH_DIR="$HOME/.ssh"
DROPBEAR_AUTH_KEYS="/system/etc/dropbear/authorized_keys"
if [[ -d "$SSH_DIR" ]]; then
  # Try to find a public key (common names)
  for key_file in "$SSH_DIR"/id_rsa.pub "$SSH_DIR"/id_ed25519.pub "$SSH_DIR"/id_ecdsa.pub "$SSH_DIR"/id_dsa.pub; do
    if [[ -f "$key_file" ]]; then
      log "Found SSH public key: $(basename "$key_file")"
      log "Copying SSH public key to dropbear authorized_keys..."
      
      # Read public key content
      KEY_CONTENT=$(cat "$key_file")
      
      # Create dropbear directory on device
      "$ADB_BIN" shell 'mkdir -p /system/etc/dropbear' >/dev/null 2>&1 || true
      
      # Append key to authorized_keys directly using echo (or create if doesn't exist)
      "$ADB_BIN" shell "
        set -e
        AUTH_KEYS=\"${DROPBEAR_AUTH_KEYS}\"
        KEY_CONTENT='$(printf '%s' "$KEY_CONTENT" | sed "s/'/'\\\\''/g")'
        # Append key to authorized_keys (or create if doesn't exist)
        echo \"\$KEY_CONTENT\" >> \"\$AUTH_KEYS\" 2>/dev/null || {
          # If append failed, try creating new file
          echo \"\$KEY_CONTENT\" > \"\$AUTH_KEYS\" 2>/dev/null || true
        }
        # Set proper permissions for authorized_keys
        chmod 0644 \"\$AUTH_KEYS\" 2>/dev/null || true
      " >/dev/null 2>&1 || true
      
      SSH_KEY_COPIED=true
      log "SSH public key installed to ${DROPBEAR_AUTH_KEYS}"
      break
    fi
  done
  
  if [[ "$SSH_KEY_COPIED" == false ]]; then
    log "No SSH public key found in $SSH_DIR (checked: id_rsa.pub, id_ed25519.pub, id_ecdsa.pub, id_dsa.pub)"
  fi
else
  log "SSH directory $SSH_DIR not found, skipping SSH key copy"
fi

log "Syncing file system..."
"$ADB_BIN" shell sync >/dev/null || true

log "Done. Installed:"
log "  - /system/usr/sbin/dropbearmulti (binary)"
log "  - Symbolic links: dropbear, dropbearkey, dropbearconvert, ssh, scp"
log "  - /system/etc/init.d/dropbear (init.d script)"
log "  - /system/etc/rc5.d/S10dropbear -> ../init.d/dropbear"
log "  - Root password set to: oemlinux1"
if [[ "$SSH_KEY_COPIED" == true ]]; then
  log "  - SSH public key installed to /system/etc/dropbear/authorized_keys"
fi
log ""
log "Reboot if desired: adb reboot"


