# Stalwart mail platform — remaining work

Everything left to get this from "installed" to "carrying real mail", in
order. Work top to bottom; each step says how to prove it worked before
you move on.

Placeholders: `<domain>` your mail domain, `<mailbox-ip>` / `<mx1-ip>` /
`<mx2-ip>` the Terraform outputs, `mail.<domain>` the mailbox server.

---

## 0. Know where you are

- [ ] Infrastructure exists (`terraform apply` has run)
- [ ] The Ansible run finished green
- [ ] You can SSH in: `ssh mailadmin@<mailbox-ip>`
- [ ] The service is up:
      `sudo systemctl is-active stalwart` → `active`

If any of these fail, start at step 1. If all pass, jump to step 2.

---

## 1. Deploy or update

### 1a. Infrastructure

```sh
cd deploy/azure/terraform
cp terraform.tfvars.example terraform.tfvars   # first time only
$EDITOR terraform.tfvars                       # domain, admin_cidr, ssh_public_key
terraform init
terraform plan
terraform apply
```

`apply` writes `../ansible/inventory/hosts.yml` for you — no copying IPs.

Record the outputs:

```sh
terraform output mx_public_ips
terraform output mailbox_public_ip
```

### 1b. Configuration

```sh
cd ../ansible
ansible-galaxy install -r requirements.yml

# first time only
cd inventory/group_vars/mailservers
cp vault.yml.example vault.yml
$EDITOR vault.yml            # set a long random vault_stalwart_admin_password
ansible-vault encrypt vault.yml
cd -

ansible-playbook site.yml --ask-vault-pass
```

**If your servers were built before the admin-credential fix, you must
re-run this.** Earlier versions wrote a malformed
`STALWART_RECOVERY_ADMIN`, which left no way to log in. Re-running
rewrites it correctly and restarts the service.

**Proof:** the play ends green. Its smoke test asserts the service is
running, every expected port accepts connections, and `/healthz/live`
returns 200 — so green genuinely means serving, not merely installed.

---

## 2. Get into the admin UI

- [ ] Browse to **`https://mail.<domain>/login`**

  Bare `/` returns 404 — use `/login` (or `/admin`, which redirects there).

- [ ] Sign in as **`admin`** with your `vault_stalwart_admin_password`
- [ ] Accept the certificate warning

The warning is expected: Stalwart serves a self-signed certificate until
you set up ACME in step 4, which you can only reach by getting in first.

Prefer not to click through a warning? Tunnel to the plain-HTTP listener,
which is bound locally but deliberately not exposed:

```sh
ssh -L 8080:127.0.0.1:8080 mailadmin@<mailbox-ip>
# then http://127.0.0.1:8080/login
```

If the page does not render at all, the host could not fetch the web UI —
Stalwart downloads it from GitHub on first start. Confirm egress:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com
```

---

## 3. Settle outbound port 25

Do this before configuring mail flow — it decides how you set up sending.

Full detail, including why the portal cannot answer this: **[PORT25.md](PORT25.md)**

### 3a. Test it, from the mailbox server

```sh
ssh mailadmin@<mailbox-ip>
nc -vz -w 10 gmail-smtp-in.l.google.com 25
```

- **succeeded** → nothing to do, skip to step 4
- **times out** → blocked (the platform drops packets rather than
  refusing). Continue.

An NSG showing port 25 "open" does not contradict this. That rule governs
*inbound* mail to your MX nodes and is correct. The outbound block is
enforced in Azure's fabric and appears nowhere in the portal.

### 3b. Check your subscription type

Portal → **Subscriptions** → your subscription → **Overview** → *Offer*.

| Type | Outcome |
| --- | --- |
| Enterprise Agreement, Enterprise Dev/Test | Exemption available → 3c |
| Pay-As-You-Go, CSP, MOSP, Visual Studio, trial, sponsored | Permanent → 3d |

### 3c. Path A — take the exemption (EA / Dev-Test only)

- [ ] Portal → your VNet (`vnet-mail`) → **Help** → **Diagnose and solve
      problems** → **Cannot send email (SMTP-Port 25)** → run it
- [ ] **Deallocate and restart** every VM — a reboot does *not* apply the
      new policy:

      ```sh
      az vm deallocate -g rg-mail -n vm-mail-mail && az vm start -g rg-mail -n vm-mail-mail
      az vm deallocate -g rg-mail -n vm-mail-mx1  && az vm start -g rg-mail -n vm-mail-mx1
      az vm deallocate -g rg-mail -n vm-mail-mx2  && az vm start -g rg-mail -n vm-mail-mx2
      ```

- [ ] Re-run the 3a test — it should now succeed

### 3d. Path B — relay through a smarthost

Not a downgrade: a new Azure IP has no sending reputation, so a relay
usually delivers better than direct port 25 would have.

- [ ] Choose a provider with authenticated submission on **587**; collect
      host, username, password
- [ ] In the Stalwart web admin, add it as the default **outbound route**
      (host, port 587, TLS on, credentials)
- [ ] Note their SPF mechanism for step 5

---

## 4. Configure Stalwart (web admin)

All of this lives in Stalwart's data store, not in this repo — 0.16 keeps
domains, accounts, TLS and routing there.

- [ ] **Add your domain.** This also generates the DKIM key and shows you
      the DNS records for step 5.
- [ ] **Create accounts** for each mailbox, plus any aliases and groups.
- [ ] **Enable ACME/TLS** so Stalwart obtains real certificates.
      Requires `mail.<domain>` to resolve to `<mailbox-ip>` and port 443
      reachable — so do step 5's A records first if they are not live.
- [ ] **Trust the MX edges as inbound relays.** The mailbox server must
      accept relayed mail for your domains from the MX private addresses.
      Get them from the generated inventory:

      ```sh
      grep -A2 -E 'mx[12]\.' deploy/azure/ansible/inventory/hosts.yml
      ```

      Without this, Postfix relays correctly and Stalwart rejects at the
      final hop.
- [ ] **Set outbound routing** — the smarthost from 3d, or direct if you
      took Path A.

---

## 5. DNS

- [ ] **A records:** `mx1` → `<mx1-ip>`, `mx2` → `<mx2-ip>`,
      `mail` → `<mailbox-ip>`
- [ ] **MX records** for `<domain>`:

      ```
      <domain>.  MX  10  mx1.<domain>.
      <domain>.  MX  20  mx2.<domain>.
      ```

      Point these at the **MX nodes, not** `mail.<domain>` — the mailbox
      server's NSG only accepts port 25 from inside the VNet.
- [ ] **PTR / reverse DNS** for whichever IP sends. Set `reverse_fqdn` on
      the Azure public IP; the Terraform already assigns each IP a DNS
      label, which is the prerequisite. Skip if you relay via a smarthost —
      their IPs do the sending.
- [ ] **SPF** — authorise whatever sends:

      ```
      v=spf1 include:<relay-spf-domain> -all      # Path B
      v=spf1 ip4:<mx1-ip> ip4:<mx2-ip> -all       # Path A, direct
      ```

- [ ] **DKIM** — publish the record Stalwart generated in step 4
- [ ] **DMARC** — start in monitoring mode, tighten later:

      ```
      _dmarc.<domain>.  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@<domain>"
      ```

- [ ] Optional: autoconfig/autodiscover records so clients self-configure

**Proof:** `dig MX <domain>`, `dig TXT <domain>`, `dig TXT _dmarc.<domain>`
all return what you published, and `dig -x <sending-ip>` matches its
hostname.

---

## 6. Test end to end

- [ ] **Inbound:** send from an outside account (Gmail, etc.) to a mailbox
      you created. It should arrive. Watch it land:

      ```sh
      ssh mailadmin@<mx1-ip>  'sudo journalctl -u postfix -f'
      ssh mailadmin@<mailbox-ip> 'sudo journalctl -u stalwart -f'
      ```

- [ ] **Outbound:** reply from the Stalwart account and confirm delivery.
- [ ] **Client access:** connect a real mail client.

      **Use port 465 (implicit TLS), not 587.** Stalwart 0.16 binds
      465/993 by default and does *not* bind 587 or 143. See the port
      table below.

- [ ] **Reputation check:** send to a scoring service such as
      mail-tester.com and confirm SPF, DKIM, DMARC and PTR all pass.

### What is actually listening

Verified against 0.16.9 — a bootstrapped server binds:

| Port | Service | Exposed to internet by the NSG? |
| --- | --- | --- |
| 25 | SMTP | MX nodes only (by design) |
| 443 | HTTPS — JMAP, API, web admin | yes |
| 465 | Submission, implicit TLS | yes |
| 993 | IMAPS | yes |
| 995 | POP3S | no |
| 4190 | ManageSieve | no |
| 8080 | plain HTTP | no |

There is deliberately **no 587 or 143** — 0.16 prefers the implicit-TLS
ports. If you need them, add the listeners in the web admin, then add the
ports to `stalwart_expected_ports` (or the smoke test will disagree with
reality) and open them in the NSG.

---

## 7. Operations

- [ ] **Back up the mail store.** It lives on the data disk at
      `/var/lib/stalwart`. Azure disk snapshots are the simplest route;
      schedule them. Nothing in this deployment backs anything up yet.
- [ ] **Confirm certificate renewal** happens automatically once ACME is
      configured — check again a few days before the first expiry.
- [ ] **Upgrades:** bump `stalwart_version` in your group_vars and re-run
      the play. The smoke test gates the upgrade; a failed start fails the
      run.
- [ ] **Monitoring:** at minimum alert on the service being down and on
      the data disk filling. `/healthz/live` on 443 is a ready-made probe.
- [ ] **Rotating the admin password:** change it in `vault.yml`, re-run the
      play. It is re-read at every start, so no reinstall is needed.

---

## 8. Known gaps

Real, and deliberately not hidden:

- **Backups are not automated.** See step 7.
- **The MX→Stalwart trust is a manual web-admin step** (step 4). Stalwart
  0.16 keeps it in the data store, so the role cannot template it.
- **SQL store backends are unverified.** `rocksdb` and `sqlite` are tested
  against the real binary; PostgreSQL/MySQL descriptor field names are
  best-effort, with `stalwart_store_descriptor` as the escape hatch.
- **RHEL-family support is untested.** CI covers Debian 13 and Ubuntu
  24.04/26.04 only.
- **No authenticated-login test in CI.** Molecule proves the server runs
  and serves, but never logs in — which is exactly how the malformed admin
  credential passed a green pipeline. Worth adding.

### Repository housekeeping

- [ ] Delete the `circleci-project-setup` branch (CircleCI's sample, unused)
- [ ] Delete `HANDOFF.md` once its root-cause notes are no longer useful
