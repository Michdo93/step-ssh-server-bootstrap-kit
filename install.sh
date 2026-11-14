#!/usr/bin/env bash
#
# step SSH Server Bootstrap Kit - makes an OpenSSH server trust SSH user certificates from a
# step-ca (TrustedUserCAKeys), optionally maps certificate principals to local accounts
# (e.g. a "sysadmin" certificate may also log in as root) and restarts sshd safely.
# Supports: Debian, Ubuntu, Raspberry Pi OS, DietPi.
#
#   curl -fsSL https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/install.sh | sudo bash -s -- \
#     --ca-url https://192.168.0.150 --fingerprint <sha256-of-root-ca>
#
# Options:
#   --ca-url URL          step-ca URL (e.g. https://192.168.0.150 or https://ca.home.arpa:9000)
#   --fingerprint FP      SHA-256 fingerprint of the CA root certificate
#   --map USER=P1[,P2]    local account USER also accepts certificates with principal P1, P2
#                         (repeatable), e.g. --map root=sysadmin --map openhab=sysadmin
#   --ensure-user NAME    create the local account NAME if it is missing (home, bash, no usable
#                         password - certificate login only), repeatable or comma separated
#   --sudo-user NAME      like --ensure-user and add NAME to the sudo group
#   --switch-dropbear     DietPi with Dropbear: replace Dropbear by OpenSSH (dietpi-software)
#   --no-restart          only write and test the configuration, do not restart sshd
#   --yes                 no questions
#   --no-color            plain output
#
# Re-running is safe: it refreshes the CA keys (e.g. after a CA key rotation) and keeps the
# configuration. Mappings can be changed later with map-principals.sh.
#
# Everything is inside main(), which is only called on the last line.

set -euo pipefail

KIT="step-ssh-server-bootstrap-kit"
CONF_DIR="/etc/step-ssh-server"
STEP_DIR="$CONF_DIR/step"
USER_CA_FILE="/etc/ssh/step_ca_user_keys.pub"
HOST_CA_FILE="$CONF_DIR/ssh_host_ca_keys.pub"
PRINC_DIR="/etc/ssh/auth_principals"
PRINC_CMD="/usr/local/sbin/step-ssh-principals"
DROPIN="/etc/ssh/sshd_config.d/05-step-ca.conf"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
LOG_FILE="${LOG_FILE:-/var/log/$KIT.log}"

main() {
    setup_colors "${NO_COLOR:-}"
    CA_URL="${STEP_CA_URL:-}"
    FINGERPRINT="${STEP_FINGERPRINT:-}"
    ASSUME_YES="${ASSUME_DEFAULTS:-0}"
    RESTART=1
    SWITCH_DROPBEAR=0
    MAPS=()
    ENSURE_USERS=()
    SUDO_USERS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --ca-url) CA_URL="${2:?}"; shift 2 ;;
            --ca-url=*) CA_URL="${1#*=}"; shift ;;
            --fingerprint) FINGERPRINT="${2:?}"; shift 2 ;;
            --fingerprint=*) FINGERPRINT="${1#*=}"; shift ;;
            --map) MAPS+=("${2:?}"); shift 2 ;;
            --map=*) MAPS+=("${1#*=}"); shift ;;
            --ensure-user) IFS=',' read -r -a _u <<<"${2:?}"; ENSURE_USERS+=("${_u[@]}"); shift 2 ;;
            --sudo-user) IFS=',' read -r -a _u <<<"${2:?}"; ENSURE_USERS+=("${_u[@]}"); SUDO_USERS+=("${_u[@]}"); shift 2 ;;
            --switch-dropbear) SWITCH_DROPBEAR=1; shift ;;
            --no-restart) RESTART=0; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --no-color) setup_colors 1; shift ;;
            -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
            *) error "Unknown option: $1 (see --help)" ;;
        esac
    done
    interactive=0
    if have_tty && [ "$ASSUME_YES" != 1 ]; then interactive=1; fi

    check_root
    check_os
    read_previous
    ask_parameters
    ensure_packages
    ensure_step
    fetch_ca_keys
    install_principals_command
    ensure_users
    apply_maps
    configure_sshd
    restart_sshd
    summary
}

# ---------------------------------------------------------------- helpers
setup_colors() {
    if [ -t 1 ] && [ -z "${1:-}" ]; then
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
    else
        RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
    fi
}
log()   { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; log "INFO $1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; log "WARN $1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; log "ERROR $1"; exit 1; }
step_msg() { printf "${BLUE}==>${NC} %s\n" "$1"; log "STEP $1"; }
have_tty() { (exec </dev/tty) 2>/dev/null; }
ask() {
    local reply
    printf '%s' "$1" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
    printf '%s' "${reply:-$2}"
}

check_root() {
    [ "$(id -u)" -eq 0 ] && return
    command -v sudo >/dev/null 2>&1 && error "Please run with sudo: curl -fsSL <url> | sudo bash -s -- [options]  (or: sudo $0 ...)"
    error "This script must be run as root."
}

check_os() {
    [ -r /etc/os-release ] || error "Cannot detect the operating system (/etc/os-release missing)."
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*|*" raspbian "*) ;;
        *) command -v apt-get >/dev/null 2>&1 || error "Unsupported OS '${ID:-unknown}'."
           warn "OS '${ID:-unknown}' is not officially tested; continuing because apt-get exists." ;;
    esac
    local d=""
    [ -f /boot/dietpi/.version ] && d=" (DietPi)"
    info "Detected OS: ${PRETTY_NAME:-$ID}$d ($(uname -m))"
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null || error "apt-get update failed."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" </dev/null >/dev/null ||
        error "Installing $* failed."
}

read_previous() {
    if [ -f "$CONF_DIR/server.conf" ]; then
        # shellcheck disable=SC1091
        . "$CONF_DIR/server.conf"
        CA_URL="${CA_URL:-${PREV_CA_URL:-}}"
        FINGERPRINT="${FINGERPRINT:-${PREV_FINGERPRINT:-}}"
        info "Existing installation found ($CONF_DIR/server.conf) - updating it."
    fi
}

ask_parameters() {
    if [ -z "$CA_URL" ] && [ "$interactive" = 1 ]; then
        CA_URL=$(ask "step-ca URL (e.g. https://192.168.0.150): " "")
    fi
    [ -n "$CA_URL" ] || error "--ca-url is required."
    case "$CA_URL" in https://*) ;; *) error "The CA URL must start with https:// ($CA_URL)." ;; esac
    CA_URL="${CA_URL%/}"
    if [ -z "$FINGERPRINT" ] && [ "$interactive" = 1 ]; then
        FINGERPRINT=$(ask "Root fingerprint (on the CA: step certificate fingerprint \$(step path)/certs/root_ca.crt): " "")
    fi
    FINGERPRINT=$(printf '%s' "$FINGERPRINT" | tr -d ' :' | tr 'A-F' 'a-f')
    printf '%s' "$FINGERPRINT" | grep -Eq '^[0-9a-f]{64}$' || error "The fingerprint must be 64 hex characters (SHA-256)."
}

# Dropbear (DietPi default) cannot use SSH certificates - OpenSSH is required.
check_dropbear() {
    [ -x /usr/sbin/sshd ] && return 0
    command -v dropbear >/dev/null 2>&1 || pgrep -x dropbear >/dev/null 2>&1 || return 0
    if [ -x /boot/dietpi/dietpi-software ]; then
        if [ "$SWITCH_DROPBEAR" != 1 ] && [ "$interactive" = 1 ]; then
            case "$(ask "Dropbear cannot use SSH certificates. Replace it by OpenSSH now (dietpi-software)? (yes/no) [no]: " no)" in
                y|Y|yes|Yes|j|ja) SWITCH_DROPBEAR=1 ;;
            esac
        fi
        [ "$SWITCH_DROPBEAR" = 1 ] ||
            error "This DietPi uses Dropbear, which cannot use SSH certificates. Re-run with --switch-dropbear or run: dietpi-software install 105 (OpenSSH Server)."
        step_msg "Replacing Dropbear by OpenSSH (dietpi-software install 105)"
        warn "Your current SSH session runs over Dropbear - if it drops, reconnect and re-run this script."
        /boot/dietpi/dietpi-software install 105 </dev/null || error "dietpi-software install 105 failed."
        [ -x /usr/sbin/sshd ] || error "OpenSSH is still not installed."
        info "OpenSSH server installed by dietpi-software."
    else
        error "Dropbear is used as SSH server; it cannot use SSH certificates. Install openssh-server and remove dropbear first."
    fi
}

ensure_packages() {
    check_dropbear
    local missing=()
    [ -x /usr/sbin/sshd ] || missing+=(openssh-server)
    command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing ${missing[*]} ..."
        apt_install "${missing[@]}"
    fi
    [ -x /usr/sbin/sshd ] || error "OpenSSH server (/usr/sbin/sshd) is not installed."
    local v
    v=$(ssh -V 2>&1 | head -n 1 || true)
    info "OpenSSH: ${v:-unknown}"
}

ensure_step() {
    if ! command -v step >/dev/null 2>&1; then
        step_msg "Installing the step CLI (step-cli-bootstrap)"
        local bs
        bs=$(mktemp)
        curl -fsSL "${STEP_CLI_BOOTSTRAP_URL:-https://raw.githubusercontent.com/Michdo93/step-cli-bootstrap/main/install.sh}" -o "$bs" ||
            { rm -f "$bs"; error "Cannot download step-cli-bootstrap."; }
        ASSUME_DEFAULTS=1 sh "$bs" --yes </dev/null || { rm -f "$bs"; error "Installing the step CLI failed."; }
        rm -f "$bs"
        hash -r
    fi
    command -v step >/dev/null 2>&1 || error "step CLI is missing."
    info "step: $(step version 2>/dev/null | head -n 1)"
}

# ---------------------------------------------------------------- CA keys
fetch_ca_keys() {
    step_msg "Fetching the SSH user CA key from $CA_URL"
    install -d -m 0755 "$CONF_DIR"
    install -d -m 0700 "$STEP_DIR"
    export STEPPATH="$STEP_DIR"
    step ca bootstrap --ca-url "$CA_URL" --fingerprint "$FINGERPRINT" --force </dev/null >/dev/null 2>&1 ||
        error "step ca bootstrap failed (URL reachable? fingerprint correct? URL host must be in the CA's dnsNames; proxy -> NO_PROXY)."
    info "Root certificate verified against the fingerprint ($STEP_DIR/certs/root_ca.crt)."

    local tmp roots
    tmp=$(mktemp)
    # /ssh/roots over TLS verified with the root certificate above
    roots=$(curl -fsS --cacert "$STEP_DIR/certs/root_ca.crt" "$CA_URL/ssh/roots") ||
        { rm -f "$tmp"; error "Cannot read $CA_URL/ssh/roots - is SSH enabled on the CA? (step-ca-ssh.sh enable-ssh)"; }
    printf '%s' "$roots" | extract_keys userKey >"$tmp"
    if ! [ -s "$tmp" ] || ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; error "The CA did not return a usable SSH user CA key (SSH not enabled on the CA?)."
    fi
    if [ -f "$USER_CA_FILE" ] && cmp -s "$tmp" "$USER_CA_FILE"; then
        info "SSH user CA key unchanged."
    else
        [ -f "$USER_CA_FILE" ] && cp -p "$USER_CA_FILE" "$USER_CA_FILE.bak-$(date +%Y%m%d-%H%M%S)"
        install -m 0644 "$tmp" "$USER_CA_FILE"
        info "SSH user CA key written to $USER_CA_FILE"
    fi
    printf '%s' "$roots" | extract_keys hostKey >"$tmp" || true
    install -m 0644 "$tmp" "$HOST_CA_FILE"
    rm -f "$tmp"
    while IFS= read -r l; do info "  trusted: $l"; done < <(ssh-keygen -l -f "$USER_CA_FILE")
    {
        echo "# written by $KIT - re-run install.sh to change"
        echo "PREV_CA_URL='$CA_URL'"
        echo "PREV_FINGERPRINT='$FINGERPRINT'"
    } >"$CONF_DIR/server.conf"
}

# JSON {"userKey":["AAAA..."],"hostKey":[...]} -> "<type> <base64>" lines (no jq needed)
extract_keys() {  # userKey|hostKey
    local b64 type
    tr -d '\n ' | sed -n "s/.*\"$1\":\[\([^]]*\)\].*/\1/p" | tr ',' '\n' | tr -d '"' |
    while IFS= read -r b64 || [ -n "$b64" ]; do
        [ -n "$b64" ] || continue
        # the key type is the first length-prefixed string inside the blob
        type=$(printf '%s' "$b64" | base64 -d 2>/dev/null | head -c 64 | tail -c +5 | tr -cd 'a-z0-9@.-' | grep -oE '^(ecdsa-sha2-nistp(256|384|521)|ssh-ed25519|ssh-rsa)' || true)
        [ -n "$type" ] && printf '%s %s step-ca-%s\n' "$type" "$b64" "$1"
    done
}

# ---------------------------------------------------------------- principals
install_principals_command() {
    install -d -m 0755 "$PRINC_DIR"
    install -d -m 0755 "$(dirname "$PRINC_CMD")"
    cat >"$PRINC_CMD.tmp" <<EOF
#!/bin/sh
# $KIT: principals accepted for the local account \$1.
# Always the account name itself (OpenSSH default), plus the lines of $PRINC_DIR/<account>.
u="\$1"
case "\$u" in ""|*/*|.*) exit 0 ;; esac
printf '%s\n' "\$u"
[ -f "$PRINC_DIR/\$u" ] && grep -Ev '^[[:space:]]*(#|\$)' "$PRINC_DIR/\$u"
exit 0
EOF
    chown root:root "$PRINC_CMD.tmp"
    chmod 0755 "$PRINC_CMD.tmp"
    mv -f "$PRINC_CMD.tmp" "$PRINC_CMD"
}

valid_name() { [[ "$1" =~ ^[a-z_][a-z0-9_.-]{0,31}\$?$ ]]; }

ensure_users() {
    [ ${#ENSURE_USERS[@]} -gt 0 ] || return 0
    step_msg "Local accounts"
    local u s
    mapfile -t ENSURE_USERS < <(printf '%s\n' "${ENSURE_USERS[@]}" | awk 'NF && !seen[$0]++')
    for u in "${ENSURE_USERS[@]}"; do
        valid_name "$u" || error "Invalid user name '$u'."
        if id "$u" >/dev/null 2>&1; then
            info "  $u exists"
        else
            useradd -m -s /bin/bash "$u" || error "useradd $u failed."
            # "*" = no password login possible, but NOT locked ("!"): sshd with UsePAM=no
            # rejects even key/certificate logins for locked accounts.
            usermod -p '*' "$u"
            info "  $u created (no password - certificate login only)"
        fi
        for s in "${SUDO_USERS[@]}"; do
            [ "$s" = "$u" ] || continue
            getent group sudo >/dev/null 2>&1 || { warn "  group sudo does not exist - $u not added"; continue; }
            if id -nG "$u" | tr ' ' '\n' | grep -qx sudo; then info "  $u already in group sudo"
            else usermod -aG sudo "$u"; info "  $u added to group sudo (sudo still asks for a password - set one with: passwd $u)"; fi
        done
    done
}

apply_maps() {
    [ ${#MAPS[@]} -gt 0 ] || return 0
    step_msg "Principal mappings"
    local m user list p f
    for m in "${MAPS[@]}"; do
        case "$m" in *=*) ;; *) error "--map expects USER=PRINCIPAL[,PRINCIPAL] (got '$m')." ;; esac
        user="${m%%=*}"; list="${m#*=}"
        valid_name "$user" || error "Invalid user name '$user'."
        id "$user" >/dev/null 2>&1 || warn "Local account '$user' does not exist (yet) - the mapping is stored anyway."
        f="$PRINC_DIR/$user"
        touch "$f"; chmod 0644 "$f"
        IFS=',' read -r -a _ps <<<"$list"
        for p in "${_ps[@]}"; do
            valid_name "$p" || error "Invalid principal '$p'."
            if grep -qxF "$p" "$f"; then info "  $user <- $p (already present)"
            else echo "$p" >>"$f"; info "  $user <- $p"; fi
        done
    done
}

# ---------------------------------------------------------------- sshd
sshd_block() {
    cat <<EOF
# BEGIN $KIT (managed - do not edit, re-run install.sh)
TrustedUserCAKeys $USER_CA_FILE
AuthorizedPrincipalsCommand $PRINC_CMD %u
AuthorizedPrincipalsCommandUser nobody
# END $KIT
EOF
}

uses_dropin_dir() {
    grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"
}

remove_block_from() {  # file
    sed -i "/^# BEGIN $KIT/,/^# END $KIT/d" "$1"
}

configure_sshd() {
    step_msg "Configuring sshd"
    [ -f "$SSHD_CONFIG" ] || error "$SSHD_CONFIG not found."
    BACKUP_DIR="$CONF_DIR/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -p "$SSHD_CONFIG" "$BACKUP_DIR/"
    [ -f "$DROPIN" ] && cp -p "$DROPIN" "$BACKUP_DIR/"

    if uses_dropin_dir; then
        remove_block_from "$SSHD_CONFIG"     # older versions of this kit / manual copies
        sshd_block >"$DROPIN"
        chmod 0644 "$DROPIN"
        info "Written $DROPIN"
    else
        # No Include (e.g. Debian 10/11 images): the block must come BEFORE the first
        # "Match" section, otherwise it would only apply inside that Match block.
        remove_block_from "$SSHD_CONFIG"
        local blk
        blk=$(mktemp)
        sshd_block >"$blk"
        if grep -Eqi '^[[:space:]]*Match[[:space:]]' "$SSHD_CONFIG"; then
            awk -v f="$blk" 'BEGIN{done=0} !done && tolower($0) ~ /^[ \t]*match[ \t]/ { while ((getline l < f) > 0) print l; print ""; done=1 } {print}' \
                "$SSHD_CONFIG" >"$SSHD_CONFIG.new"
        else
            { cat "$SSHD_CONFIG"; echo; cat "$blk"; } >"$SSHD_CONFIG.new"
        fi
        rm -f "$blk"
        cat "$SSHD_CONFIG.new" >"$SSHD_CONFIG"; rm -f "$SSHD_CONFIG.new"
        info "Managed block added to $SSHD_CONFIG (no sshd_config.d include)."
    fi

    mkdir -p /run/sshd 2>/dev/null || true
    local out
    if ! out=$(/usr/sbin/sshd -t 2>&1); then
        rollback_sshd
        error "sshd -t rejected the configuration - rolled back. Output: $out"
    fi
    # The FIRST value of a directive wins in sshd. Make sure nobody else sets it earlier.
    local eff
    eff=$(/usr/sbin/sshd -T 2>/dev/null | awk 'tolower($1)=="trustedusercakeys"{print $2}')
    if [ "$eff" != "$USER_CA_FILE" ]; then
        warn "Effective TrustedUserCAKeys is '$eff', not '$USER_CA_FILE' - another file sets it first:"
        grep -RniE '^[[:space:]]*TrustedUserCAKeys' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null >&2 || true
        rollback_sshd
        error "Remove the other TrustedUserCAKeys line (or point it to $USER_CA_FILE) and re-run."
    fi
    eff=$(/usr/sbin/sshd -T 2>/dev/null | awk 'tolower($1)=="authorizedprincipalscommand"{print $2}')
    if [ "$eff" != "$PRINC_CMD" ]; then
        warn "Effective AuthorizedPrincipalsCommand is '$eff' - mappings (--map) will not work."
    fi
    if /usr/sbin/sshd -T 2>/dev/null | grep -qi '^pubkeyauthentication no'; then
        warn "PubkeyAuthentication is disabled - certificates cannot be used until you enable it."
    fi
    info "sshd -t: configuration OK."
}

rollback_sshd() {
    warn "Restoring the previous sshd configuration from $BACKUP_DIR"
    cp -p "$BACKUP_DIR/$(basename "$SSHD_CONFIG")" "$SSHD_CONFIG"
    if [ -f "$BACKUP_DIR/$(basename "$DROPIN")" ]; then cp -p "$BACKUP_DIR/$(basename "$DROPIN")" "$DROPIN"; else rm -f "$DROPIN"; fi
}

ssh_service() {
    local s
    for s in ssh.service sshd.service; do
        systemctl cat "$s" >/dev/null 2>&1 && { echo "$s"; return; }
    done
    echo ""
}

restart_sshd() {
    if [ "$RESTART" != 1 ]; then
        warn "sshd was NOT restarted (--no-restart). Run: sudo systemctl restart ssh"
        return
    fi
    step_msg "Restarting sshd (existing SSH sessions stay open)"
    local svc=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || [ -n "${FORCE_SYSTEMCTL:-}" ]; then
        svc=$(ssh_service)
    fi
    if [ -n "$svc" ]; then
        systemctl restart "$svc" || error "systemctl restart $svc failed - check: journalctl -u $svc"
        sleep 1
        systemctl is-active "$svc" >/dev/null 2>&1 || error "$svc is not running after the restart - check: journalctl -u $svc"
        info "$svc restarted."
    elif command -v service >/dev/null 2>&1 && [ -x /etc/init.d/ssh ]; then
        service ssh restart >/dev/null || error "service ssh restart failed."
        info "ssh restarted (init script)."
    elif pgrep -x sshd >/dev/null 2>&1; then
        pkill -HUP -x sshd
        info "sshd reloaded (SIGHUP)."
    else
        warn "sshd does not seem to run - start it to use the new configuration."
    fi
}

summary() {
    printf '\n%bDone.%b This SSH server now accepts user certificates signed by the step-ca.\n' "$GREEN" "$NC"
    printf '  CA:                 %s\n' "$CA_URL"
    printf '  TrustedUserCAKeys:  %s\n' "$USER_CA_FILE"
    printf '  Principal mapping:  %s/<account>  (account name is always accepted)\n' "$PRINC_DIR"
    local f any=0
    for f in "$PRINC_DIR"/*; do
        [ -f "$f" ] || continue
        any=1
        printf '      %-12s <- %s\n' "$(basename "$f")" "$(grep -Ev '^[[:space:]]*(#|$)' "$f" | paste -sd, -)"
    done
    [ "$any" = 1 ] || printf '      (none - a certificate for principal X logs in as account X)\n'
    printf '\n  Login needs an existing local account. Test from a client:\n'
    printf '    ssh -i ~/.ssh/step_<principal> <account>@%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf '  Debug on this server: journalctl -u ssh -f   (look for "Accepted publickey ... ID ... CA")\n\n'
}

main "$@"
