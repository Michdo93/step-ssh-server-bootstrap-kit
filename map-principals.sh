#!/usr/bin/env bash
#
# step SSH Server Bootstrap Kit - manage which certificate principals may log in to which
# local account. No sshd restart needed: sshd asks /usr/local/sbin/step-ssh-principals
# at every login.
#
#   sudo ./map-principals.sh --list
#   sudo ./map-principals.sh --add root sysadmin          # sysadmin certificate -> also root
#   sudo ./map-principals.sh --add openhab sysadmin,ansible
#   sudo ./map-principals.sh --remove root sysadmin
#   sudo ./map-principals.sh --remove root                # remove all extra principals of root
#
#   curl -fsSL https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/map-principals.sh | sudo bash -s -- --add root sysadmin

set -euo pipefail

PRINC_DIR="/etc/ssh/auth_principals"
PRINC_CMD="/usr/local/sbin/step-ssh-principals"

main() {
    if [ -t 1 ]; then GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'; else GREEN=''; RED=''; YELLOW=''; NC=''; fi
    [ "$(id -u)" -eq 0 ] || error "Please run as root (sudo)."
    [ -x "$PRINC_CMD" ] || error "$PRINC_CMD missing - run install.sh of step-ssh-server-bootstrap-kit first."
    case "${1:-}" in
        --list|-l|"") list ;;
        --add) [ $# -eq 3 ] || error "Usage: --add ACCOUNT PRINCIPAL[,PRINCIPAL]"; add "$2" "$3"; list ;;
        --remove) [ $# -ge 2 ] || error "Usage: --remove ACCOUNT [PRINCIPAL[,PRINCIPAL]]"; remove "$2" "${3:-}"; list ;;
        --test) [ $# -eq 2 ] || error "Usage: --test ACCOUNT"; printf 'Principals accepted for %s:\n' "$2"; "$PRINC_CMD" "$2" | sed 's/^/  /' ;;
        -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *) error "Unknown option $1 (see --help)" ;;
    esac
}

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; exit 1; }
valid_name() { [[ "$1" =~ ^[a-z_][a-z0-9_.-]{0,31}\$?$ ]]; }

add() {
    valid_name "$1" || error "Invalid account '$1'."
    id "$1" >/dev/null 2>&1 || warn "Local account '$1' does not exist (yet)."
    install -d -m 0755 "$PRINC_DIR"
    local f="$PRINC_DIR/$1" p
    touch "$f"; chmod 0644 "$f"
    IFS=',' read -r -a ps <<<"$2"
    for p in "${ps[@]}"; do
        valid_name "$p" || error "Invalid principal '$p'."
        grep -qxF "$p" "$f" || echo "$p" >>"$f"
        info "$1 <- $p"
    done
}

remove() {
    local f="$PRINC_DIR/$1" p
    [ -f "$f" ] || { warn "No mapping for '$1'."; return 0; }
    if [ -z "$2" ]; then rm -f "$f"; info "All extra principals of '$1' removed."; return 0; fi
    IFS=',' read -r -a ps <<<"$2"
    for p in "${ps[@]}"; do
        grep -vxF "$p" "$f" >"$f.tmp" || true
        cat "$f.tmp" >"$f"; rm -f "$f.tmp"
        info "$1 <- $p removed"
    done
    [ -s "$f" ] || rm -f "$f"
}

list() {
    printf 'Account        extra principals (the account name itself is always accepted)\n'
    local f any=0
    for f in "$PRINC_DIR"/*; do
        [ -f "$f" ] || continue
        any=1
        printf '  %-12s %s\n' "$(basename "$f")" "$(grep -Ev '^[[:space:]]*(#|$)' "$f" | paste -sd, -)"
    done
    [ "$any" = 1 ] || printf '  (none)\n'
}

main "$@"
