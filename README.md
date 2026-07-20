# Ansible Role: Stalwart Mail Server

[![CircleCI](https://dl.circleci.com/status-badge/img/gh/jnix85/ansible-role-stalwart-mail-server/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/jnix85/ansible-role-stalwart-mail-server/tree/main)

Installs and configures [Stalwart](https://stalw.art) — an all-in-one mail &
collaboration server (SMTP, IMAP, JMAP, POP3, CalDAV/CardDAV) — from the
official release binaries, running under systemd as a dedicated unprivileged
user.

## Features

- **Debian/Ubuntu and RHEL/Rocky/Alma (EL9)** support
- **Native binary install** to `/opt/stalwart`, version-pinned and upgradeable
  by bumping `stalwart_version`
- **Configurable TLS**: Stalwart's built-in ACME (Let's Encrypt), existing
  certificate files, or a generated self-signed cert for labs
- **Configurable storage**: RocksDB (default, zero dependencies), SQLite, or
  an external PostgreSQL
- **Per-protocol listener toggles**: SMTP, submission (STARTTLS + implicit
  TLS), IMAP/IMAPS, POP3, ManageSieve, HTTPS (JMAP/API/web admin)
- **Hardened systemd unit** (non-root, `ProtectSystem=strict`,
  `CAP_NET_BIND_SERVICE` only)
- **Optional firewall management** (ufw/firewalld)
- Admin password is required up front (Vault-friendly) and stored on the host
  only as a SHA512-crypt hash

## Requirements

- Ansible **2.15+** on the controller
- A systemd-based target on `x86_64` or `aarch64`
- Collections `community.general` and `ansible.posix` (only when
  `stalwart_manage_firewall: true`) — see `requirements.yml`
- Outbound HTTPS from the target to `github.com` (or override
  `stalwart_download_url` to point at an internal mirror)

## Quick start

```yaml
- hosts: mailservers
  become: true
  roles:
    - role: jnix85.stalwart_mail_server
      vars:
        stalwart_hostname: mail.example.com
        stalwart_admin_password: "{{ vault_stalwart_admin_password }}"
        stalwart_tls_mode: acme
        stalwart_acme_contact: postmaster@example.com
        stalwart_acme_domains:
          - mail.example.com
```

After the first run, open `https://mail.example.com` and log in to the web
admin as `admin` with the password you supplied. Domains, accounts, DKIM
signing and most runtime settings are managed there (or via the CLI/API) and
are stored in the database — this role manages the *local* bootstrap
configuration (listeners, storage, TLS, logging).

## Role variables

Defaults live in [`defaults/main.yml`](defaults/main.yml). The important ones:

### Version & install

| Variable | Default | Description |
| --- | --- | --- |
| `stalwart_version` | `"0.16.9"` | Release to install (tag without `v`). Changing it upgrades in place. |
| `stalwart_download_url` | GitHub release URL | Override for mirrors or if upstream asset naming changes. |
| `stalwart_download_checksum` | `""` | Optional, e.g. `sha256:abc...`. |
| `stalwart_libc` | `gnu` | `gnu` or `musl` release flavour. |
| `stalwart_install_dir` | `/opt/stalwart` | Install prefix (`bin/`, `etc/`, `data/`, `logs/`). |
| `stalwart_user` / `stalwart_group` | `stalwart` | Dedicated system account the daemon runs as. |

### Identity & admin

| Variable | Default | Description |
| --- | --- | --- |
| `stalwart_hostname` | `ansible_fqdn` | FQDN the server identifies as. Set this explicitly in production. |
| `stalwart_admin_user` | `admin` | Fallback administrator account name. |
| `stalwart_admin_password` | — | **Required**, min 12 chars. Supply via Ansible Vault. |

### TLS (`stalwart_tls_mode`)

| Mode | Description |
| --- | --- |
| `acme` | Stalwart obtains/renews certificates itself. Configure `stalwart_acme_contact`, `stalwart_acme_domains`, `stalwart_acme_challenge` (`tls-alpn-01` default — requires port 443 reachable from the internet; also `http-01`, `dns-01`). |
| `files` | Use existing certs: set `stalwart_tls_cert_file` and `stalwart_tls_key_file` (must be readable by the `stalwart` user; remember to restart Stalwart when they renew). |
| `selfsigned` | **Default.** Role generates a self-signed cert under `etc/certs/`. Labs and testing only. |

### Storage (`stalwart_storage_backend`)

| Backend | Description |
| --- | --- |
| `rocksdb` | **Default.** Embedded store under `stalwart_data_dir`. Best single-node choice. |
| `sqlite` | Embedded SQL store, fine for small deployments. |
| `postgresql` | External PostgreSQL — set `stalwart_postgresql_host/port/database/user/password`. The role does **not** install PostgreSQL. |

### Listeners

Each protocol has an `_enabled` toggle and a `_port` variable:

| Toggle | Default | Port(s) |
| --- | --- | --- |
| `stalwart_smtp_enabled` | `true` | 25 |
| `stalwart_submission_enabled` | `true` | 587 (STARTTLS) |
| `stalwart_submissions_enabled` | `true` | 465 (implicit TLS) |
| `stalwart_imap_enabled` | `true` | 143 (STARTTLS) |
| `stalwart_imaps_enabled` | `true` | 993 (implicit TLS) |
| `stalwart_pop3_enabled` | `false` | 110 / 995 |
| `stalwart_managesieve_enabled` | `false` | 4190 |
| `stalwart_https_enabled` | `true` | 443 (JMAP, REST API, web admin) |
| `stalwart_http_enabled` | `false` | 8080 (plaintext, for reverse proxies) |

### Firewall

`stalwart_manage_firewall: false` by default. When enabled, the role opens the
enabled listener ports via **ufw** (Debian family) or **firewalld** (RedHat
family). It deliberately does **not** run `ufw enable` — activating a firewall
with a default-deny policy could cut off your SSH session. Enable ufw yourself
after allowing SSH.

### Everything else

`stalwart_extra_config` accepts raw TOML appended verbatim to `config.toml`
for any local setting the role doesn't model.

## Example: existing certs + PostgreSQL

```yaml
- hosts: mailservers
  become: true
  roles:
    - role: jnix85.stalwart_mail_server
      vars:
        stalwart_hostname: mail.example.com
        stalwart_admin_password: "{{ vault_stalwart_admin_password }}"
        stalwart_tls_mode: files
        stalwart_tls_cert_file: /etc/letsencrypt/live/mail.example.com/fullchain.pem
        stalwart_tls_key_file: /etc/letsencrypt/live/mail.example.com/privkey.pem
        stalwart_storage_backend: postgresql
        stalwart_postgresql_host: db.internal
        stalwart_postgresql_password: "{{ vault_stalwart_pg_password }}"
        stalwart_manage_firewall: true
```

## After installation: DNS checklist

The role sets up the server; deliverability needs DNS:

1. **A/AAAA** record for `stalwart_hostname`
2. **MX** record for each mail domain pointing at `stalwart_hostname`
3. **PTR** (reverse DNS) on the server IP matching `stalwart_hostname`
4. **SPF**, **DKIM** and **DMARC** — Stalwart generates DKIM keys when you add
   a domain in the web admin and shows you the exact records to publish

## Testing

```sh
pip install ansible-core molecule molecule-plugins[docker] docker ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml
molecule test                       # Debian 12 (default)
MOLECULE_DISTRO=rockylinux9 molecule test
```

Note: Molecule resolves the role by its Galaxy name, so clone this repository
into a directory named `jnix85.stalwart_mail_server` (CircleCI does this
automatically).

CI runs on [CircleCI](https://circleci.com): a lint job (yamllint +
ansible-lint) gates a Molecule matrix across Debian 12, Rocky Linux 9 and
Ubuntu 24.04.

## License

MIT

## Author

jnix85
