# Azure mail platform (Terraform + Ansible)

This directory builds a small, opinionated mail platform on Azure in two stages.
**Stage 1 (Terraform)** creates a resource group, one VNet/subnet, and three
Ubuntu 24.04 LTS VMs with static public IPs: `mx1` and `mx2` (Postfix + rspamd
edge relays) and `mail` (the Stalwart mailbox server), each behind a network
security group scoped to its job. **Stage 2 (Ansible)** configures them: the MX
nodes become relay-only Postfix hosts that scan with rspamd and forward accepted
mail to the mailbox server over the private VNet address, and the mailbox host
gets Stalwart installed via the `jnix85.stalwart_mail_server` role from this
repository. Terraform renders the Ansible inventory itself, so no IP addresses
are copied by hand between the stages. This is a working starting point, not a
turnkey production mail system — read [Known manual steps and
limitations](#known-manual-steps-and-limitations) and the [outbound port 25
warning](#warning-azure-blocks-outbound-port-25) before you rely on it.

> **Working through a deployment?** [RUNBOOK.md](RUNBOOK.md) is the
> ordered checklist of everything left to do, from `terraform apply` to
> DNS, testing and backups.

## Traffic flow

```text
                 inbound mail (the internet)
                            |
                       :25  |  :25
              +-------------+-------------+
              |                           |
        +-----v-----+               +-----v-----+          NSG: nsg-mail-mx
        |    mx1    |               |    mx2    |          in: 25/tcp  Internet
        |  postfix  |               |  postfix  |              80/tcp  Internet (certbot)
        |  + rspamd |               |  + rspamd |              22/tcp  admin_cidr
        +-----+-----+               +-----+-----+
              |                           |
              |   private VNet, :25 to the mailbox private IP
              +-------------+-------------+
                            |
                      +-----v------+                       NSG: nsg-mail-mailbox
   mail clients  -->  |    mail    |                        in: 25/tcp  VNet CIDR only
   :443 (web admin)   |  Stalwart  |                            443,465,587,993  Internet
   :465 :587 (submit) |            |                            22/tcp  admin_cidr
   :993 (IMAPS)       +------------+
```

The mailbox server never takes port 25 from the internet: the NSG allows 25 only
from the VNet CIDR, so inbound mail must arrive through `mx1`/`mx2`. Client
protocols (submission, IMAPS, HTTPS/web admin) go straight to the mailbox host.

## Sizing and images

| Host | Role | vCPU / RAM | OS disk | Data disk |
| --- | --- | --- | --- | --- |
| `mx1`, `mx2` | Postfix relay + rspamd | 2 vCPU / 4 GB (current-gen burstable B-series) | 30 GB | — |
| `mail` | Stalwart mailbox server | 2 vCPU / 8 GB | 30 GB | 64 GB managed disk, LUN 0, mounted at `/var/lib/stalwart` |

- All three run **Ubuntu 24.04 LTS** (Canonical marketplace image). 30 GB is the
  minimum OS disk the 24.04 image accepts.
- The mailbox server's **mail store lives on the data disk** at
  `/var/lib/stalwart`, not on the OS disk, so it can be grown or detached
  independently. The Ansible stage partitions/formats it (if empty), mounts it
  via `/etc/fstab`, and points Stalwart's data directory at the mount.
- An **arm64 option** is available through the `vm_architecture` variable. arm64
  B-series sizes are cheaper for the same vCPU/RAM, and both Stalwart and the
  Ubuntu packages used here have aarch64 builds. Set it in `terraform.tfvars`
  before the first apply — switching architecture later means recreating the
  VMs.
- Exact size strings and other defaults live in `terraform/variables.tf`; check
  there rather than trusting a value quoted in prose.

## Prerequisites

- An **Azure subscription** and `az` CLI logged in (`az login`), with a
  subscription selected (`az account set --subscription <id>`). Terraform's
  `azurerm` provider uses that context.
- **Terraform** >= 1.5.
- **Ansible** 2.15+ on your workstation, plus `git` (the role is installed from
  a git source).
- An **SSH keypair**; the public key goes into `terraform.tfvars`.
- A **DNS zone you control** for the mail domain(s). DNS is not managed by this
  Terraform — you create the records yourself (see the
  [DNS checklist](#post-deploy-dns-checklist)).
- An admin source CIDR for SSH (`admin_cidr`). Use your office/VPN range, not
  `0.0.0.0/0`.
- A decision about outbound port 25 — see
  [the warning below](#warning-azure-blocks-outbound-port-25).

## Layout

```text
deploy/azure/
├── README.md                       # this file
├── terraform/
│   ├── main.tf                     # providers, the three-VM map, resource group
│   ├── variables.tf                # region, domain, admin_cidr, sizes, architecture, CIDRs
│   ├── network.tf                  # VNet, subnet, MX NSG, mailbox NSG, NIC associations
│   ├── vms.tf                      # static public IPs, NICs, VMs, mailbox data disk
│   ├── outputs.tf                  # IP outputs + renders the Ansible inventory
│   ├── terraform.tfvars.example    # copy to terraform.tfvars
│   └── templates/
│       └── hosts.yml.tftpl         # inventory template (mx_edges / mailservers)
└── ansible/
    ├── ansible.cfg                 # inventory = inventory/hosts.yml
    ├── requirements.yml            # jnix85.stalwart_mail_server + collections
    ├── site.yml                    # mx.yml then mailbox.yml
    ├── playbooks/
    │   ├── mx.yml                  # postfix relay + rspamd milter + certbot
    │   ├── mailbox.yml             # applies the Stalwart role
    │   └── templates/
    │       ├── postfix-main.cf.j2
    │       ├── postfix-transport.j2
    │       └── rspamd-worker-proxy.inc.j2
    └── inventory/
        ├── hosts.yml               # GENERATED by terraform apply (gitignored)
        └── group_vars/
            ├── all/vars.yml        # mail_domains, acme_contact
            ├── mx_edges/vars.yml   # relay target, mx_letsencrypt_enabled, size limit
            └── mailservers/
                ├── vars.yml        # Stalwart role settings (ACME, rocksdb, CLI)
                └── vault.yml.example
```

`ansible/inventory/hosts.yml` is written by Terraform on every apply and is
gitignored — never edit it by hand.

## Stage 1 — Terraform

```bash
cd deploy/azure/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars     # domain, admin_cidr, ssh_public_key, location, sizes
```

At minimum set `domain`, `admin_cidr` and `ssh_public_key`; `domain` is what the
inventory hostnames are built from (`mx1.<domain>`, `mx2.<domain>`,
`mail.<domain>`), so it must match the DNS zone you will publish records in.

```bash
terraform init
terraform plan
terraform apply
```

On success you get:

```bash
terraform output mx_public_ips        # -> MX records point here
terraform output mailbox_public_ip    # -> A record for the mailbox host
terraform output ansible_inventory_path
```

and `../ansible/inventory/hosts.yml` is rendered with both the public IPs
(`ansible_host`) and the private VNet IPs (`private_ip`, used to build the
Postfix transport map and the Stalwart relay trust list), grouped as `mx_edges`
and `mailservers`.

**Create the DNS A records for `mx1`, `mx2` and `mail` now**, before Stage 2 —
the MX playbook's Let's Encrypt step needs them to resolve (see
[Let's Encrypt on the MX nodes](#lets-encrypt-on-the-mx-nodes)).

## Stage 2 — Ansible

```bash
cd deploy/azure/ansible
ansible-galaxy install -r requirements.yml
```

That pulls the `jnix85.stalwart_mail_server` role (from this repo) plus the
`community.crypto`, `community.general` and `ansible.posix` collections.

Set the domains and ACME contact:

```bash
$EDITOR inventory/group_vars/all/vars.yml         # mail_domains, acme_contact
$EDITOR inventory/group_vars/mailservers/vars.yml # Stalwart role knobs (optional)
```

Create the vault with the Stalwart admin password:

```bash
cd inventory/group_vars/mailservers
cp vault.yml.example vault.yml
$EDITOR vault.yml            # set vault_stalwart_admin_password to something long and random
ansible-vault encrypt vault.yml
cd -
```

Check connectivity, then deploy:

```bash
ansible -m ping all --ask-vault-pass
ansible-playbook site.yml --ask-vault-pass
```

`site.yml` runs, in order:

1. **`playbooks/mx.yml`** against `mx_edges` — installs Postfix, rspamd, Redis
   and certbot; obtains a Let's Encrypt cert per MX hostname via HTTP-01
   standalone (skippable, see below); writes a **relay-only** `main.cf`
   (`mydestination` empty, local delivery disabled, `relay_domains` =
   `mail_domains`); writes and `postmap`s a transport map sending each mail
   domain to `smtp:[<mailbox private IP>]:25`; configures rspamd as a milter on
   `127.0.0.1:11332`; starts everything and waits for the SMTP listener.
2. **`playbooks/mailbox.yml`** against `mailservers` — prepares/mounts the data
   disk and applies the `jnix85.stalwart_mail_server` role with ACME TLS
   (Let's Encrypt via the port-443 listener), the RocksDB storage backend, and
   `stalwart-cli` installed. The host firewall is left off on purpose because
   the NSG is already the enforcement point; flip `stalwart_manage_firewall` on
   if you want defense in depth.

To re-run just one half:

```bash
ansible-playbook playbooks/mx.yml
ansible-playbook playbooks/mailbox.yml --ask-vault-pass
```

After the run, the Stalwart web admin is at `https://mail.<domain>/` — log in as
`admin` with the vaulted password.

### Let's Encrypt on the MX nodes

`playbooks/mx.yml` runs `certbot certonly --standalone`, i.e. **HTTP-01 on port
80** (the MX NSG opens 80 from the internet for exactly this). That means
`mx1.<domain>` and `mx2.<domain>` **must already resolve to the right public IPs
before you run the playbook**, or certbot fails.

If DNS is not ready yet, do a first pass with it disabled:

```yaml
# inventory/group_vars/mx_edges/vars.yml
mx_letsencrypt_enabled: false
```

Postfix then falls back to the packaged **snakeoil** certificate — inbound
STARTTLS still works, but the certificate does not validate. Set the toggle back
to `true` and re-run `playbooks/mx.yml` once DNS has propagated. Certbot's
systemd renewal timer handles renewals; if you later automate a
`--deploy-hook`, note that Postfix must be reloaded after each renewal.

## Post-deploy DNS checklist

Work through all of these before you consider the platform live. Values come
from `terraform output`.

- [ ] **A records** — `mx1.<domain>`, `mx2.<domain>` and `mail.<domain>` each
      pointing at the matching static public IP.
- [ ] **MX records** — for **every** domain in `mail_domains`, pointing at
      `mx1.<domain>` and `mx2.<domain>` (e.g. priority `10` and `20`). Do **not**
      point MX at `mail.<domain>` — its NSG rejects port 25 from the internet, so
      mail sent there will never be delivered.
- [ ] **PTR / reverse DNS for the sending IP** — whichever host actually sends
      outbound mail must have a PTR matching its HELO name. Set it on the Azure
      public IP resource via its `reverse_fqdn` property; Azure requires the
      public IP to carry a DNS name label first, which this Terraform already
      assigns. Example:

      ```bash
      az network public-ip update \
        --resource-group <resource_group_name> \
        --name pip-mail-mail \
        --reverse-fqdn mail.example.com.
      ```

      (Note the trailing dot, and make sure `mail.example.com` resolves to that
      IP first, or Azure rejects the update.)
- [ ] **SPF** — a TXT record on each mail domain authorising your sending
      hosts/relay.
- [ ] **DKIM** — a TXT record at `<selector>._domainkey.<domain>` carrying the
      public key.
- [ ] **DMARC** — a TXT record at `_dmarc.<domain>`; start at `p=none` with a
      reporting address and tighten once reports look clean.

**Get the exact SPF/DKIM/DMARC record text from Stalwart.** After you add a
domain in the Stalwart web admin UI, it generates the DKIM keypair and shows the
precise DNS records to publish — copy them from there rather than hand-writing
them. Verify afterwards:

```bash
dig +short MX example.com
dig +short A mx1.example.com
dig +short -x <mailbox-public-ip>
dig +short TXT _dmarc.example.com
```

## WARNING: Azure blocks outbound port 25

> **Step-by-step: [PORT25.md](PORT25.md)** — how to tell whether you
> are actually blocked, whether your subscription can be exempted, and how to
> relay if it cannot. Read that if you are acting on this; the summary below
> is context.

**Azure blocks outbound TCP/25 by default on most subscription types** —
pay-as-you-go, CSP, MSDN/Visual Studio, free trial, and others, where it is
permanent and cannot be lifted. Only Enterprise Agreement and Enterprise
Dev/Test subscriptions can be exempted. Nothing in this deployment can work
around that.

Note that this block is invisible in the portal: it is enforced in Azure's
network fabric, not by an NSG rule, so an NSG showing port 25 "open" (which
ours does, for *inbound* mail to the MX nodes) says nothing about whether the
server can send.

- **Inbound mail is unaffected.** Internet → `mx1`/`mx2` on port 25, and the
  MX → mailbox hop inside the VNet, both work normally.
- **Outbound mail will fail.** Any message the mailbox server (or an MX host)
  tries to deliver directly to an external MX will time out.

Your two options:

1. **Request an unblock.** Raise it through the Azure portal support flow for
   removing the port 25 restriction. Microsoft grants this case by case and, in
   practice, generally only to Enterprise Agreement customers who provide a
   justification and an anti-abuse story. Do not assume you will get it.
2. **Relay outbound mail through a smarthost** — an email delivery provider or
   any relay reachable on 587/465. Configure it in Stalwart's outbound routing
   (and, if the MX hosts ever send, in Postfix's `relayhost`). This is the path
   most deployments end up on, and it also inherits the provider's IP
   reputation, which is usually better than a fresh Azure IP's.

**Decide this before going to production.** A platform that receives mail
perfectly and cannot send is a bad surprise to discover after cutover. If you
plan to use a smarthost, note that SPF and DKIM must then cover that provider,
which changes the records in the checklist above.

## Known manual steps and limitations

Be aware of these — they are real gaps, not paperwork.

1. **The Stalwart ↔ MX relay trust is not automated.** The mailbox host must
   be told to accept relayed mail for `mail_domains` from the MX nodes' private
   VNet IPs. Stalwart 0.16 keeps that setting in its data store rather than in
   a configuration file, so the role cannot template it: configure it in the
   **web admin** at `https://<mailbox host>/` after the first deploy — add the
   domain, then set the trusted relay sources and outbound routing. Until this
   is done, inbound mail may be rejected at the final hop even though Postfix
   relays it correctly. The MX private IPs are in the generated inventory as
   `hostvars[<mx host>].private_ip` for each host in `groups['mx_edges']`.
2. **Outbound routing is likewise not configured** — see the port 25 warning. If
   you use a smarthost, set it in Stalwart.
3. **No end-to-end test is included.** After deploying, send a real message in
   and watch it traverse the path:

   ```bash
   # on mx1/mx2
   sudo tail -f /var/log/mail.log
   # on the mailbox host
   sudo journalctl -u stalwart -f
   ```
4. **No high availability for the mailbox server.** `mx1`/`mx2` give you a
   redundant, queueing front door, but `mail` is a single VM with a single data
   disk. Back up `/var/lib/stalwart`; Azure disk snapshots are the simple
   option.
5. **No backups, monitoring or log shipping** are configured.
6. **rspamd runs with stock settings** — no trained Bayes, no custom scoring, no
   greylisting. Expect to tune it.
7. **`admin_cidr` is the only SSH restriction.** There is no bastion, and the
   NSG is the sole gate; the host firewall on the mailbox server is deliberately
   off.
8. **DNS is not managed by Terraform.** Every record in the checklist is manual.

## Cost

Three burstable B-series VMs, three managed OS disks, one 64 GB data disk, and
three **static** public IPs (static IPs bill even while a VM is deallocated), all
in one region. Egress is billed too, though mail volumes are small.

No dollar figures are quoted here because prices vary by region, currency and
over time — price it yourself with the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for
your region using the sizes in `terraform/variables.tf`.

Ways to reduce it:

- Set **`vm_architecture` to arm64**; arm64 B-series sizes cost less than their
  x86 equivalents at the same vCPU/RAM.
- Standard SSD (the default here) is cheaper than Premium SSD; the data disk can
  start small since it is easy to grow later.
- Deallocate the environment when you are only testing (`az vm deallocate`) —
  compute stops billing, disks and static IPs do not.
- A lab that does not need MX redundancy can drop to a single MX node by editing
  the VM map in `terraform/main.tf`.

## Teardown

```bash
cd deploy/azure/terraform
terraform destroy
```

This removes the resource group and everything in it — **including the mailbox
data disk and all stored mail**. Snapshot or export anything you want to keep
first. The static public IPs are released too, so you will get new addresses (and
need new DNS/PTR) if you rebuild; clean up the stale DNS records afterwards.
`../ansible/inventory/hosts.yml` is left behind on disk — delete it manually if
you want a clean tree.
