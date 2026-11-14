# step SSH Server Bootstrap Kit

Makes an **OpenSSH server** accept **SSH user certificates** from a [step-ca](https://smallstep.com/docs/step-ca/):
downloads and verifies the **SSH user CA key**, configures `TrustedUserCAKeys`, sets up an optional
**principal mapping** (e.g. a `sysadmin` certificate may also log in as `root`), tests the configuration
with `sshd -t` and restarts sshd.

Supported: **Debian, Ubuntu, Raspberry Pi OS and DietPi**. Part of the set
[step-ca-ssh-bootstrap-kit](https://github.com/Michdo93/step-ca-ssh-bootstrap-kit) (CA) ·
**step-ssh-server-bootstrap-kit** (servers) ·
[step-ssh-client-bootstrap-kit](https://github.com/Michdo93/step-ssh-client-bootstrap-kit) (clients).

## Quick start

As root or with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/install.sh | sudo bash -s -- \
  --ca-url https://192.168.0.150 --fingerprint <sha256-of-the-root-certificate>
```

With principal mapping (certificate `sysadmin` may also log in as `root` and `openhabvm`):

```bash
curl -fsSL https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/install.sh | sudo bash -s -- \
  --ca-url https://192.168.0.150 --fingerprint <sha256> --map root=sysadmin --map openhabvm=sysadmin
```

Get the fingerprint on the CA: `step certificate fingerprint $(step path)/certs/root_ca.crt`
(or `step-ca-ssh.sh info`).

## What it does

1. **Privileges / OS:** root check, Debian/Ubuntu/Raspberry Pi OS/DietPi detection.
2. **Packages:** `openssh-server` and `curl` if missing; the **step CLI** via
   [step-cli-bootstrap](https://github.com/Michdo93/step-cli-bootstrap) if missing.
3. **CA trust:** `step ca bootstrap` into `/etc/step-ssh-server/step` – the root certificate is only accepted
   if its **SHA-256 fingerprint matches**. Then `GET /ssh/roots` over TLS verified with that root →
   `/etc/ssh/step_ca_user_keys.pub` (backup if it changed).
4. **Principals:** `/usr/local/sbin/step-ssh-principals` (`AuthorizedPrincipalsCommand`) accepts for an
   account always **its own name** (OpenSSH default) **plus** the lines of `/etc/ssh/auth_principals/<account>`.
   New accounts therefore work without extra files, mappings can be changed without restarting sshd.
5. **sshd:**
   - with `Include /etc/ssh/sshd_config.d/*.conf` (Debian 12+, Ubuntu 22.04+): `05-step-ca.conf`
   - without (older images): a managed block in `sshd_config` **before the first `Match`** section
   - `sshd -t` must pass, and `sshd -T` must show **our** `TrustedUserCAKeys` (the first value wins in sshd –
     another file setting it earlier is detected) – otherwise the old configuration is restored.
6. **Restart:** `systemctl restart ssh` (or `sshd`, init script, SIGHUP). Existing sessions stay open.

Re-running is safe (idempotent) and refreshes the CA keys, e.g. after a CA key rotation.

## Options

| Option | Meaning |
|---|---|
| `--ca-url URL` | step-ca URL, e.g. `https://192.168.0.150` (host must be in the CA's `dnsNames`) |
| `--fingerprint FP` | SHA-256 fingerprint of the root certificate |
| `--map USER=P1[,P2]` | account `USER` also accepts principals `P1`, `P2` (repeatable) |
| `--no-restart` | write and test only |
| `--yes` | no questions |
| `--no-color` | plain output |

## More scripts

| Script | Purpose |
|---|---|
| `map-principals.sh --list \| --add ACCOUNT P1[,P2] \| --remove ACCOUNT [P] \| --test ACCOUNT` | change the mapping later (no restart) |
| `fetch-ca-keys.sh --ca-url URL --fingerprint FP [--out DIR]` | download `root_ca.crt`, `ssh_user_ca.pub`, `ssh_host_ca.pub`, `known_hosts.step` – verified, **only curl + openssl, no root** |
| `uninstall.sh [--keep-mappings] [--yes]` | remove the trust again (keys/passwords keep working) |

## Example output

```text
[INFO] Detected OS: Ubuntu 22.04 LTS (x86_64)
==> Fetching the SSH user CA key from https://192.168.0.150
[INFO] Root certificate verified against the fingerprint (/etc/step-ssh-server/step/certs/root_ca.crt).
[INFO] SSH user CA key written to /etc/ssh/step_ca_user_keys.pub
==> Principal mappings
[INFO]   root <- sysadmin
==> Configuring sshd
[INFO] Written /etc/ssh/sshd_config.d/05-step-ca.conf
[INFO] sshd -t: configuration OK.
[INFO] ssh.service restarted.
```

## Security notes

- The login still needs an **existing local account**. A certificate for `ansible` cannot log in as `root`
  unless you map it (`--map root=ansible`) – think twice before mapping to `root`.
- `authorized_keys` and passwords keep working. Disable them only after certificate logins are tested.
- Debug on the server: `journalctl -u ssh -f` – a certificate login shows
  `Accepted publickey for … ID <key id> (serial …) CA ECDSA …`.
- Log: `/var/log/step-ssh-server-bootstrap-kit.log`, backups: `/etc/step-ssh-server/backup-*`.

## License

MIT License. Feel free to use and modify.
