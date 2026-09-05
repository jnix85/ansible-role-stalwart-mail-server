# Ansible Role: Stalwart Mail Server

[![CircleCI](https://dl.circleci.com/status-badge/img/gh/jnix85/ansible-role-stalwart-mail-server/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/jnix85/ansible-role-stalwart-mail-server/tree/main)

Installs and configures [Stalwart](https://stalw.art) — an all-in-one mail &
collaboration server (SMTP, IMAP, JMAP, POP3, CalDAV/CardDAV) — from the
official release binaries, running under systemd as a dedicated unprivileged
user.

## Features

- **Debian 13 and Ubuntu 24.04/26.04** support (the primary, CI-tested
  targets; RHEL-family code paths exist but are currently untested)
- **Native binary install** to `/opt/stalwart`, version-pinned and upgradeable
  by bumping `stalwart_version`
- **Selectable data store**: RocksDB (default, zero dependencies), SQLite, or
  an external PostgreSQL/MySQL
- **Hardened systemd unit** (non-root, `ProtectSystem=strict`,
  `CAP_NET_BIND_SERVICE` only)
- **Optional firewall management** (ufw/firewalld), which never activates the
  firewall itself
- **Smoke test on every run**, so the play fails if the server is not actually
  serving afterwards

## How Stalwart 0.16 is configured

Read this first — it is not what most Ansible mail roles assume.

Stalwart 0.16 does **not** read a configuration file for listeners, TLS,
domains or accounts. The file passed to `stalwart --config` is a small JSON
*data store descriptor* naming the store and how to reach it:

```json
{
    "@type": "RocksDb",
    "path": "/opt/stalwart/data"
}
```

Everything else lives inside that store and is managed from the **web admin
UI** at `https://<host>/`. A few bootstrap values are passed as environment
variables on the unit instead: `STALWART_HOSTNAME`, `STALWART_PUBLIC_URL`,
`STALWART_HTTPS_PORT` and `STALWART_RECOVERY_ADMIN`.

So this role installs the binary, writes a correct descriptor, manages the
service and firewall, and proves the result is running. It deliberately does
not template listener or TLS settings, because this version ignores them.

## Requirements

- Ansible **2.15+** on the controller
- A systemd-based target on `x86_64` or `aarch64`
- Collections (see `requirements.yml`): `community.general` and
  `ansible.posix`, needed only when `stalwart_manage_firewall: true`
- Outbound HTTPS from the target to `github.com` (or override
  `stalwart_download_url` to point at an internal mirror)

## Quick start

Install the role straight from this repository:

```sh
ansible-galaxy role install \
  git+https://github.com/jnix85/ansible-role-stalwart-mail-server.git,main,jnix85.stalwart_mail_server
```

The repository root **is** the role (standard Galaxy layout), so the
command above installs it directly from git. A complete, copyable project
layout — `site.yml`, `playbooks/`, `inventory/hosts.yml`, and
`group_vars` with a vault split — lives in [`examples/`](examples/).
Minimal playbook:

```yaml
- hosts: mailservers
  become: true
  roles:
    - role: jnix85.stalwart_mail_server
      vars:
        stalwart_hostname: mail.example.com
        stalwart_admin_password: "{{ vault_stalwart_admin_password }}"
```

The play fails if the server is not serving when it finishes, so a green run
means a working daemon. Then open `https://mail.example.com/` and finish setup
in the web admin: add your domain, create accounts, and enable TLS
certificates. Stalwart also generates the exact SPF, DKIM and DMARC records to
publish from there.

Log in as `stalwart_admin_user` (default `admin`) with
`stalwart_admin_password`. The role pins that credential through
`STALWART_RECOVERY_ADMIN="<user>:<password>"`, the form the server documents
itself; a bare password is silently ignored. The value is re-read on every
start, so changing it in the vault and re-running the play rotates the
password without touching the mail store.

A server started with a config file never enters Stalwart's bootstrap mode, so
it never prints generated credentials — this pinned credential is the only way
in. Verified against 0.16.9: IMAP `LOGIN` succeeds with the pinned password
and fails with any other.

## Role variables

Defaults live in [`defaults/main.yml`](defaults/main.yml). The important ones:

### Version & install

| Variable | Default | Description |
| --- | --- | --- |
| `stalwart_version` | `"0.16.9"` | Release to install (tag without `v`). Changing it upgrades in place. |
| `stalwart_download_urls` | GitHub release URLs | Candidate URLs probed in order; covers both old (`stalwart-mail-*`) and new (`stalwart-*`) asset naming. |
| `stalwart_download_url` | `""` | Explicit override (internal mirror); skips the candidate probing. |
| `stalwart_download_checksum` | `""` | Optional, e.g. `sha256:abc...`. |
| `stalwart_libc` | `gnu` | `gnu` or `musl` release flavour. |
| `stalwart_install_dir` | `/opt/stalwart` | Install prefix (`bin/`, `etc/`, `data/`, `logs/`). |
| `stalwart_user` / `stalwart_group` | `stalwart` | Dedicated system account the daemon runs as. |
| `stalwart_cli_install` | `false` | Install a separate `stalwart-cli` binary. See the caveat below before enabling. |

Note on `stalwart_cli_install`: upstream publishes **no `stalwart-cli`
release asset** for 0.16.x — verified against the v0.16.9 release, where
every candidate asset name returns 404 — because the server binary now
carries the administrative commands itself (`stalwart --help`), alongside
the web admin UI. Leave this off unless you are installing an older
release that shipped a CLI, or you point `stalwart_cli_download_url` at a
binary you host. With it on and no such asset, the role fails fast during
install rather than deploying something broken.

### Identity & admin

| Variable | Default | Description |
| --- | --- | --- |
| `stalwart_hostname` | `ansible_fqdn` | FQDN the server identifies as. Set this explicitly in production. |
| `stalwart_public_url` | `https://{{ stalwart_hostname }}` | Base URL the web admin and generated links use. |
| `stalwart_admin_user` | `admin` | Administrator login name. |
| `stalwart_admin_password` | — | **Required**, min 12 chars. Supply via Ansible Vault. Passed to the service as `STALWART_RECOVERY_ADMIN="<user>:<password>"`. |
| `stalwart_env_file` | `<install_dir>/etc/stalwart.env` | Bootstrap environment file. Holds the admin password, so it is written `0640` root-owned. |

Note that this credential is written to the host in plain text, because the
server takes it from the environment. The file is `0640` and owned by root,
but it is not a hash.

### Storage (`stalwart_storage_backend`)

Selects the `@type` of the generated data store descriptor.

| Backend | `@type` | Description |
| --- | --- | --- |
| `rocksdb` | `RocksDb` | **Default.** Embedded store under `stalwart_data_dir`. Best single-node choice. Verified against 0.16.9. |
| `sqlite` | `Sqlite` | Embedded SQL store, fine for small deployments. Verified against 0.16.9. |
| `postgresql` | `PostgreSql` | External PostgreSQL — set `stalwart_db_host/port/name/user/password`. The role does **not** install a database. |
| `mysql` | `MySql` | External MySQL/MariaDB, same settings. |

Only the two embedded backends are verified end to end against the real
binary. The server *ignores* unknown fields in the descriptor rather than
rejecting them, so a wrong SQL field name surfaces as a connection failure at
startup. If you hit that, set `stalwart_store_descriptor` to a mapping that is
written verbatim:

```yaml
stalwart_store_descriptor:
  "@type": PostgreSql
  host: db.internal
  database: stalwart
  user: stalwart
  password: "{{ vault_stalwart_db_password }}"
```

`stalwart_data_dir` (default `<install_dir>/data`) is the store path for the
embedded backends. Point it at a dedicated disk for real deployments.

### Listeners

Listeners are configured in the web admin, not here. `stalwart_expected_ports`
records the ports a freshly bootstrapped 0.16 server binds, and the role uses
that list only to open the firewall and to verify the service is healthy:

| Port | Purpose |
| --- | --- |
| 25 | SMTP |
| 443 | HTTPS: JMAP, API, web admin |
| 465 | submissions (implicit TLS) |
| 993 | IMAPS |
| 995 | POP3S |
| 4190 | ManageSieve |
| 8080 | plain HTTP |

Note there is no 587 or 143 by default — 0.16 binds the implicit-TLS ports
instead. If you change the listeners in the web admin, update
`stalwart_expected_ports` to match or the smoke test will disagree with
reality.

### Firewall

`stalwart_manage_firewall: false` by default. When enabled, the role opens the
enabled listener ports — and removes rules for listeners you've toggled off —
via **ufw** (Debian family) or **firewalld** (RedHat family). It deliberately
never activates a firewall itself (no `ufw enable`, no starting/enabling
firewalld): switching on a default-deny firewall could cut off your SSH
session. If firewalld isn't running, rules are written permanent-only and take
effect if you start it.

### Everything else

- `stalwart_smoke_test` (default `true`): after deployment the role re-reads
  the service state, waits for `stalwart_expected_ports`, and polls
  `/healthz/live` until it returns 200. This is deliberately strict: a bad
  data store descriptor makes Stalwart exit *after* systemd has reported a
  successful start, and only a check like this catches it. Set
  `stalwart_smoke_test_host` if you probe something other than localhost.
- `stalwart_store_descriptor`: write an exact descriptor yourself, bypassing
  the backend settings entirely.

## Example: external PostgreSQL on a dedicated data disk

```yaml
- hosts: mailservers
  become: true
  roles:
    - role: jnix85.stalwart_mail_server
      vars:
        stalwart_hostname: mail.example.com
        stalwart_admin_password: "{{ vault_stalwart_admin_password }}"
        stalwart_storage_backend: postgresql
        stalwart_db_host: db.internal
        stalwart_db_password: "{{ vault_stalwart_db_password }}"
        stalwart_manage_firewall: true
```

Certificates are not in that list on purpose: request and renew them from the
web admin, which is where 0.16 keeps them.

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
molecule test                       # Debian 13 (default)
MOLECULE_DISTRO=ubuntu2404 molecule test
```

Note: Molecule resolves the role by its Galaxy name, so clone this repository
into a directory named `jnix85.stalwart_mail_server` (CircleCI does this
automatically).

CI runs on [CircleCI](https://circleci.com): a lint job (yamllint +
ansible-lint) gates a Molecule matrix across Debian 13, Ubuntu 24.04 and
Ubuntu 26.04.

## License

MIT

## Author

jnix85
