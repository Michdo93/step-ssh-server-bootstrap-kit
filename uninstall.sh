#!/usr/bin/env bash
#
# step SSH Server Bootstrap Kit - removes the step-ca trust from sshd again.
# SSH keys in authorized_keys and passwords keep working; certificate logins stop.
#
#   sudo ./uninstall.sh [--keep-mappings] [--yes]
#   curl -fsSL https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/uninstall.sh | sudo bash -s -- --yes

set -euo pipefail

KIT="step-ssh-server-bootstrap-kit"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
DROPIN="/etc/ssh/sshd_config.d/05-step-ca.conf"

main() {
    if [ -t 1 ]; then GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'; else GREEN=''; RED=''; YELLOW=''; NC=''; fi
    KEEP=0; YES="${ASSUME_DEFAULTS:-0}"
    for a in "$@"; do
        case "$a" in --keep-mappings) KEEP=1 ;; --yes|-y) YES=1 ;; *) error "Unknown option $a" ;; esac
    done
    [ "$(id -u)" -eq 0 ] || error "Please run as root (sudo)."
    if [ "$YES" != 1 ] && (exec </dev/tty) 2>/dev/null; then
        printf 'Remove step-ca certificate login from this SSH server? (yes/no) [no]: ' >/dev/tty
        read -r a </dev/tty || a=""
        case "$a" in y|Y|yes|Yes|j|ja) ;; *) error "Aborted." ;; esac
    fi
    local bak
    bak="/root/$KIT-uninstall-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bak"
    cp -p "$SSHD_CONFIG" "$bak/"
    [ -f "$DROPIN" ] && mv "$DROPIN" "$bak/"
    sed -i "/^# BEGIN $KIT/,/^# END $KIT/d" "$SSHD_CONFIG"
    mkdir -p /run/sshd 2>/dev/null || true
    if ! /usr/sbin/sshd -t; then
        cp -p "$bak/$(basename "$SSHD_CONFIG")" "$SSHD_CONFIG"
        [ -f "$bak/$(basename "$DROPIN")" ] && cp -p "$bak/$(basename "$DROPIN")" "$DROPIN"
        error "sshd -t failed after removing the block - restored."
    fi
    rm -f /usr/local/sbin/step-ssh-principals /etc/ssh/step_ca_user_keys.pub
    rm -rf /etc/step-ssh-server
    if [ "$KEEP" = 0 ] && [ -d /etc/ssh/auth_principals ]; then
        mv /etc/ssh/auth_principals "$bak/"
    fi
    if command -v systemctl >/dev/null 2>&1 && { [ -d /run/systemd/system ] || [ -n "${FORCE_SYSTEMCTL:-}" ]; }; then
        if systemctl cat ssh.service >/dev/null 2>&1; then systemctl restart ssh.service; else systemctl restart sshd.service; fi
    elif pgrep -x sshd >/dev/null 2>&1; then
        pkill -HUP -x sshd
    fi
    info "Removed. Backup of the old configuration: $bak"
}

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; exit 1; }

main "$@"
