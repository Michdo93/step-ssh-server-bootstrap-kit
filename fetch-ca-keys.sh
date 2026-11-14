#!/usr/bin/env bash
#
# Downloads the root certificate and the SSH CA public keys of a step-ca and verifies them
# against the root fingerprint. Needs only curl and openssl (no step CLI, no root).
#
#   ./fetch-ca-keys.sh --ca-url https://192.168.0.150 --fingerprint <sha256> [--out DIR]
#   curl -fsSL https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/fetch-ca-keys.sh | bash -s -- \
#     --ca-url https://192.168.0.150 --fingerprint <sha256>
#
# Writes into DIR (default ./step-ca-keys):
#   root_ca.crt          root certificate (fingerprint verified)
#   ssh_user_ca.pub      SSH user CA key(s)  -> TrustedUserCAKeys on SSH servers
#   ssh_host_ca.pub      SSH host CA key(s)
#   known_hosts.step     "@cert-authority * <host CA key>" lines for clients (host certificates)

set -euo pipefail

main() {
    CA_URL="${STEP_CA_URL:-}"; FP="${STEP_FINGERPRINT:-}"; OUT="./step-ca-keys"
    while [ $# -gt 0 ]; do
        case "$1" in
            --ca-url) CA_URL="${2:?}"; shift 2 ;;
            --fingerprint) FP="${2:?}"; shift 2 ;;
            --out) OUT="${2:?}"; shift 2 ;;
            -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) die "Unknown option $1" ;;
        esac
    done
    [ -n "$CA_URL" ] || die "--ca-url is required."
    case "$CA_URL" in https://*) ;; *) die "The CA URL must start with https://" ;; esac
    CA_URL="${CA_URL%/}"
    FP=$(printf '%s' "$FP" | tr -d ' :' | tr 'A-F' 'a-f')
    printf '%s' "$FP" | grep -Eq '^[0-9a-f]{64}$' || die "--fingerprint must be 64 hex characters (SHA-256)."
    command -v curl >/dev/null 2>&1 || die "curl is required (sudo apt install curl)."
    command -v openssl >/dev/null 2>&1 || die "openssl is required (sudo apt install openssl)."

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    # 1. download all roots WITHOUT TLS verification - trust comes from the fingerprint below
    curl -fsSk "$CA_URL/roots.pem" -o "$tmp/roots.pem" || die "Cannot download $CA_URL/roots.pem"
    awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++} n{print > (d "/c" n ".pem")}' "$tmp/roots.pem"
    found=""
    for c in "$tmp"/c*.pem; do
        [ -f "$c" ] || continue
        f=$(openssl x509 -in "$c" -outform DER | sha256sum | cut -d' ' -f1)
        [ "$f" = "$FP" ] && found="$c"
    done
    [ -n "$found" ] || die "No root certificate at $CA_URL matches the fingerprint $FP - wrong CA or man-in-the-middle!"
    mkdir -p "$OUT"
    cp "$found" "$OUT/root_ca.crt"
    echo "[OK] root_ca.crt verified: $(openssl x509 -in "$found" -noout -subject)"

    # 2. SSH keys over TLS that is now verified with the root
    if roots=$(curl -fsS --cacert "$OUT/root_ca.crt" "$CA_URL/ssh/roots" 2>/dev/null); then
        printf '%s' "$roots" | keys userKey >"$OUT/ssh_user_ca.pub"
        printf '%s' "$roots" | keys hostKey >"$OUT/ssh_host_ca.pub"
        sed 's/^/@cert-authority * /' "$OUT/ssh_host_ca.pub" >"$OUT/known_hosts.step"
        echo "[OK] ssh_user_ca.pub: $(wc -l <"$OUT/ssh_user_ca.pub") key(s), ssh_host_ca.pub: $(wc -l <"$OUT/ssh_host_ca.pub") key(s)"
    else
        echo "[WARN] $CA_URL/ssh/roots not available - SSH is not enabled on this CA (step-ca-ssh.sh enable-ssh)." >&2
    fi
    echo "Files in $OUT"
}

keys() {  # userKey|hostKey  : JSON -> "<type> <base64>" lines
    local b64 type
    tr -d '\n ' | sed -n "s/.*\"$1\":\[\([^]]*\)\].*/\1/p" | tr ',' '\n' | tr -d '"' |
    while IFS= read -r b64 || [ -n "$b64" ]; do
        [ -n "$b64" ] || continue
        type=$(printf '%s' "$b64" | base64 -d 2>/dev/null | head -c 64 | tail -c +5 | tr -cd 'a-z0-9@.-' | grep -oE '^(ecdsa-sha2-nistp(256|384|521)|ssh-ed25519|ssh-rsa)' || true)
        [ -n "$type" ] && printf '%s %s step-ca-%s\n' "$type" "$b64" "$1"
    done
}

die() { echo "[ERROR] $*" >&2; exit 1; }

main "$@"
