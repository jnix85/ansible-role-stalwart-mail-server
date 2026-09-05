# Handoff

Written to pick this work back up on another machine. Everything below is
current as of the last commit on `main`; it replaces an earlier handoff that
described a since-fixed bug.

## Where the project stands

The Ansible role is **done and working**. `main` carries it, CI is green
(lint plus Molecule on Debian 13, Ubuntu 24.04 and Ubuntu 26.04), and the
generated configuration has been verified against the real Stalwart 0.16.9
binary rather than assumed.

Merged so far: the role itself (#1), a round of code-review fixes and IPv6
auto-detection (#2), a single-source listener list and CLI toggle (#3), the
example project layout (#4), the Azure deployment plus the 0.16 config rewrite
(#5), the admin credential fix (#6), and the runbook and port-25 guidance (#7).

**Nothing is pending in the repo.** The working branch
`claude/stalwart-ansible-role-fdyujz` is level with `main`.

## Hard-won facts about Stalwart 0.16 — do not rediscover these

All verified by running the 0.16.9 binary directly, not from documentation:

- **It does not read a TOML config file.** The binary contains zero
  occurrences of `.toml`. `--config` takes a JSON *data store descriptor*:
  `{"@type":"RocksDb","path":"/opt/stalwart/data"}`. `@type` accepts
  `RocksDb`, `Sqlite`, `PostgreSql`, `MySql` (and `FoundationDb`, which the
  official builds are not compiled with).
- **Everything else lives in the data store**, managed from the web admin —
  listeners, TLS, domains, accounts, outbound routing. The role cannot
  template any of it, and inventing role variables for it will not work.
- **The admin credential must be `user:password`.** `STALWART_RECOVERY_ADMIN`
  silently ignores a bare password, leaving no way to log in. Verified over
  IMAP: `LOGIN admin <pinned password>` succeeds, a wrong password fails, and
  the value is re-read on every start so changing it rotates the credential.
- **A server started with a config file never enters bootstrap mode**, so it
  never prints generated credentials. The pinned credential is the only way in.
- **Default listeners: 25, 443, 465, 993, 995, 4190, 8080.** There is no 587
  or 143 — clients must use the implicit-TLS ports.
- **The web admin is at `/login`.** Bare `/` returns 404.
- **It logs nothing to the journal by default** (no tracer configured), so
  `journalctl -u stalwart` shows only systemd lines. Enable a tracer in the
  web admin before trying to debug anything, including ACME.
- `/healthz/live` returns 200 on both 443 and 8080.
- Release assets: `stalwart-<arch>-unknown-linux-gnu.tar.gz` exists for x86_64
  and aarch64. **No `stalwart-cli` asset exists for 0.16.x.**

## Live infrastructure reality

This diverges from what the repo builds — worth checking before assuming.

- `mail.clawduino.com` → **3.93.11.114**, an AWS EC2 instance in us-east-1,
  running Stalwart. Not the Azure deployment. Its `journalctl` showed clean
  systemd restarts, not crashes.
- `mx01`/`mx02.clawduino.com` do **not** resolve.
- `clawduino.com` itself is on Cloudflare; `mail` points straight at AWS, so
  it is grey-clouded — correct, since Cloudflare does not proxy SMTP.
- Azure: reported as "deployed but disposable" — exists, nothing real depends
  on it.
- Azure subscription is an **Azure Plan** (MCA/CSP), so outbound port 25 is
  **permanently blocked** with no request path. AWS, by contrast, grants
  removal to any account on request.
- A reserved Elastic IP **50.17.181.39** is to be used for
  `smtp.clawduino.com`.

## The pending change: four roles, multi-cloud

Designed but **not implemented** — no code written. The plan lived outside the
repo, so it is reproduced here.

### Target

| Role | Where | Purpose |
| --- | --- | --- |
| `mail` | Azure | Stalwart mailboxes, IMAP/JMAP, web admin |
| `mx01`, `mx02` | Azure | Inbound MX (Postfix + rspamd), renamed from mx1/mx2 |
| `smtp` | AWS us-east-1 | Outbound relay on EIP 50.17.181.39 |

### Decisions already taken

1. One Terraform root declaring **both** `azurerm` and `aws` providers, which
   means moving `deploy/azure/` → `deploy/`.
2. The smtp host is on AWS and delivers **directly** to recipient MX servers
   (no third-party smarthost), because Azure's block is permanent and AWS's
   is liftable.
3. Public IPs get **decoupled from VM lifecycle** so they survive renames and
   rebuilds, with existing addresses adopted where worth keeping.
4. The currently deployed AWS instance is destroyed; its role is replaced by
   the new relay on the reserved EIP.

### The key technical constraint driving the design

Azure static IPs are stable only for the life of the *public IP resource*.
Today `azurerm_public_ip.vm` is created inside the same `for_each` as the VM
and its `name` interpolates the map key, so renaming or rebuilding a VM
destroys its address. `terraform state mv` does not help — `name` and
`computer_name` are ForceNew.

The fix is an address map whose keys are permanent role slots, separate from
the VM map, with `prevent_destroy`:

```hcl
locals {
  address_slots   = { mailbox = { label = "mail" }, mx_a = { label = "mxa" }, mx_b = { label = "mxb" } }
  vm_address_slot = { mail = "mailbox", mx01 = "mx_a", mx02 = "mx_b" }
}

resource "azurerm_public_ip" "mail" {
  for_each          = local.address_slots
  name              = "pip-mail-${each.key}"
  allocation_method = "Static"
  sku               = "Standard"
  lifecycle { prevent_destroy = true }
}
```

The NIC then references
`azurerm_public_ip.mail[local.vm_address_slot[each.key]].id`. Note that
`prevent_destroy` makes `terraform destroy` fail on these by design.

### Other required changes

- **`network.tf`**: the NSG association is a binary ternary
  (`tier == "mx" ? mx : mailbox`), so any new tier silently gets the mailbox
  NSG. Replace with a map lookup keyed by tier so an unknown tier fails loudly.
  No third Azure NSG is needed — the relay is on AWS.
- **New `terraform/aws.tf`**: security group (587 inbound *only* from the
  Azure mailbox public IP, 22 from `admin_cidr`, egress all; do **not** open
  25 inbound), `aws_instance` on Ubuntu 24.04 via an `aws_ami` data source,
  and the EIP adopted by `terraform import aws_eip.smtp <allocation-id>` with
  `prevent_destroy`.
- **Inventory**: `hosts.yml.tftpl` gains a third group `smtp_relays`;
  `outputs.tf` passes a fourth key into `templatefile()`. Groups become
  `mx_edges`, `mailservers`, `smtp_relays`.
- **New `ansible/playbooks/relay.yml`** plus
  `templates/postfix-relay-main.cf.j2` and a `smtp_relays` group_vars
  directory with a vault example. The relay is the inverse of the MX template:
  no `relay_domains`, submission on 587 with
  `smtpd_sasl_auth_enable = yes`, `smtpd_tls_security_level = encrypt`,
  `smtpd_relay_restrictions = permit_sasl_authenticated, reject`, and no
  `relayhost` (direct delivery). Follow the handler-ordering convention that
  `mx.yml` documents — the map-rebuild handler is listed *before* the restart
  handler so its notify lands on a handler that has not yet run in the flush.
- **`site.yml`**: import `relay.yml` between `mx.yml` and `mailbox.yml`.
- Docs: `README.md`, `RUNBOOK.md`, `PORT25.md` all need the four-role topology
  and the new DNS.

### Wiring the mailbox to the relay

Cannot be templated — outbound routing lives in Stalwart's data store. Add the
relay as the default outbound route **in the web admin**, pointing at
`smtp.clawduino.com:587` with the SASL credential, and document it in
`RUNBOOK.md` next to the existing MX-trust step.

## Warnings before anything is applied

1. **Destroying 3.93.11.114 destroys its Stalwart data store** — mailboxes,
   accounts, domain config, DKIM keys. Confirm nothing is worth keeping. It
   currently answers as `mail.clawduino.com`, so that record must repoint to
   the Azure mailbox address, or mail access breaks.
2. **AWS port 25 removal is a prerequisite** and is per-region: the
   "Request to Remove Email Sending Limitations" form, root credentials,
   ~48h. Until granted the relay queues rather than delivers. A drafted
   justification exists in the conversation history if needed again.
3. **PTR for 50.17.181.39** is a separate AWS request and is required for
   deliverability.

## Known gaps in the role

- Backups are not automated. The mail store is on the data disk at
  `/var/lib/stalwart`; Azure disk snapshots are the simplest route.
- The MX→Stalwart relay trust is a manual web-admin step.
- PostgreSQL/MySQL descriptor field names are **unverified** — the server
  ignores unknown fields rather than rejecting them, so a wrong name surfaces
  as a connection failure. `stalwart_store_descriptor` writes an exact
  descriptor as an escape hatch. Only `rocksdb` and `sqlite` are verified.
- RHEL-family paths exist but are untested; CI covers Debian/Ubuntu only.
- **No authenticated-login test in CI.** Molecule proves the server runs and
  serves but never logs in — which is exactly how the malformed admin
  credential passed a fully green pipeline. Adding an IMAP `LOGIN` assertion
  to `molecule/default/verify.yml` using the converge password would close it.

## Housekeeping

- The `circleci-project-setup` branch is CircleCI's unused sample; safe to
  delete.
- This file can go once its contents are stale.

## Environment notes for whoever picks this up

- Commit author must be `jnix85 <jnix85@users.noreply.github.com>` — GitHub
  rejects the real address under email privacy.
- Lint locally with `yamllint .` and `ansible-lint` (needs `--offline` if
  galaxy is unreachable); both pass at the production profile today.
- CI is CircleCI, not GitHub Actions — Actions was deliberately removed.
