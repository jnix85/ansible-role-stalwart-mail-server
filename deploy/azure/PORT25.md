# Outbound port 25 on Azure — runbook

What to do about Azure's SMTP restriction for this deployment, in the
order you should do it.

## First: "the portal says port 25 is open" and "port 25 is blocked" are
## both true

They describe different things, which is why the portal is not the place
to settle this.

| | Inbound 25 (receiving mail) | Outbound 25 (sending mail) |
| --- | --- | --- |
| Controlled by | Your **NSG rules** | Azure's **platform block** |
| Visible in the portal | Yes — an allow rule | **No** — it appears nowhere in NSG |
| State in this deployment | Open on `mx1`/`mx2` by design | Blocked by default |
| Can you change it | Yes, it is your rule | Only per the eligibility below |

The NSG rule you are looking at (`allow-smtp`, port 25, source
`Internet`, on `nsg-mail-mx`) is real and correct — it is what lets the
internet deliver mail to your MX nodes. Azure has never blocked inbound
25.

The platform block is enforced in Azure's network fabric, not by any
rule on your resources. Nothing you can see in the portal will show it.
So an "open" NSG tells you nothing about whether your server can *send*.

Two related paths are also unaffected, and worth knowing so you do not
over-diagnose:

- **MX → mailbox over the VNet.** The block targets internet-bound
  traffic. Your Postfix nodes hand mail to the mailbox server on port 25
  over private VNet addresses, which is not internet-bound. Step 1 below
  includes a test if you want to confirm it on your own hosts.
- **Submission from mail clients** on 465/587 into your server. Inbound,
  and unaffected.

## Step 1 — Verify it for yourself, from the VM

Do not infer this from the portal. Run it on the **mailbox server**,
since that is the host that sends:

```sh
ssh mailadmin@<mailbox-ip>

# Known-good public MX on port 25.
nc -vz -w 10 gmail-smtp-in.l.google.com 25
```

- **`succeeded`** → outbound 25 works. Nothing further to do; skip to
  Step 5.
- **hangs, then times out** → blocked. This is the signature: the
  platform drops the packets, so you get a timeout, not a refusal.

If `nc` is not installed:

```sh
timeout 10 bash -c 'cat < /dev/null > /dev/tcp/gmail-smtp-in.l.google.com/25' \
  && echo OPEN || echo "BLOCKED or timed out"
```

Optional, to confirm the internal relay path is healthy — run on an MX
node, against the mailbox server's **private** IP:

```sh
nc -vz -w 5 <mailbox-private-ip> 25   # expect: succeeded
```

## Step 2 — Find your subscription type

This single fact determines which of the two paths you are on.

Azure Portal → **Subscriptions** → select your subscription →
**Overview** → read the **Offer** / subscription type.

| Subscription type | Outbound 25 |
| --- | --- |
| Enterprise Agreement (EA) | Exemption available — Path A |
| Enterprise Dev/Test | Exemption available — Path A |
| Pay-As-You-Go | **Permanently blocked** — Path B |
| CSP / MOSP / partner-managed | **Permanently blocked** — Path B |
| Visual Studio, Free Trial, sponsored, student | **Permanently blocked** — Path B |

For anything outside EA / Enterprise Dev-Test there is no request to
file and no exception to negotiate. Microsoft's documented position is
to use an authenticated relay instead. Go to Path B.

## Path A — Request the exemption (EA / Enterprise Dev-Test only)

Self-service; no support ticket.

1. Azure Portal → your **Virtual Network** resource (`vnet-mail`).
2. Left menu → **Help** → **Diagnose and solve problems**.
3. Choose **Cannot send email (SMTP-Port 25)**.
4. Run the diagnostic. Qualifying subscriptions are exempted
   automatically; you are told on the spot if yours does not qualify.

Then the step that is easy to miss:

5. **Stop (deallocate) and restart every VM.** A reboot is *not* enough
   — the new network policy is only attached when the VM is deallocated
   and reallocated.

   ```sh
   az vm deallocate -g rg-mail -n vm-mail-mail
   az vm start      -g rg-mail -n vm-mail-mail
   # repeat for vm-mail-mx1 and vm-mail-mx2 if you want them exempt too
   ```

   A guest-OS `shutdown` does **not** deallocate. Use the CLI above, or
   the portal's **Stop** button.

6. Re-run the Step 1 test. It should now succeed.

Scope notes: the exemption covers the whole subscription going forward,
and applies only to traffic routed **directly** to the internet — if you
later force egress through a firewall or NVA, it does not apply.

## Path B — Relay outbound mail through a smarthost

This is the normal outcome, and it is not a downgrade. A brand-new Azure
IP has no sending reputation, so many receivers would treat your mail
with suspicion even if 25 were open. A relay with established reputation
usually *improves* deliverability.

1. **Pick a relay** that offers authenticated SMTP submission on port
   587 (any transactional email provider does; so do most business mail
   hosts). You need: hostname, port 587, username, password.

2. **Configure it in Stalwart**, not in this repo — 0.16 keeps routing
   in its data store:

   - Open `https://<mailbox-host>/login`, sign in as `admin`.
   - Go to the outbound routing / SMTP relay settings.
   - Add the relay host with port 587, TLS enabled, and its credentials.
   - Make it the default outbound route.

3. **Update SPF** for each sending domain to authorise the relay. Your
   provider publishes the exact mechanism to add, usually an `include:`:

   ```
   v=spf1 include:<relay-provider-spf-domain> -all
   ```

   If you had listed your own IPs, keep them only if you also send
   directly from them.

4. **Leave DKIM with Stalwart.** It signs before handing the message to
   the relay, so your DKIM record stays the one Stalwart generates when
   you add the domain.

5. Send a test message and confirm it arrives and passes SPF/DKIM/DMARC
   at the receiving end.

## Step 5 — Either way, finish the mail setup

Unchanged by which path you took:

- MX records for each domain → `mx1` and `mx2` (priority 10 and 20),
  **not** the mailbox server.
- A records for `mx1`, `mx2`, `mail`.
- PTR / reverse DNS on the sending IP, matching its hostname. Set it on
  the Azure public IP resource (`reverse_fqdn`); the Terraform already
  gives each IP a DNS label, which is the prerequisite.
- SPF, DKIM, DMARC — Stalwart shows you the exact records to publish
  once you add the domain in the web admin.
- Configure the MX edges as trusted inbound relays in the Stalwart web
  admin, using the MX private IPs from the generated inventory.

## Quick reference

| Symptom | Cause | Fix |
| --- | --- | --- |
| Inbound mail never arrives | DNS/MX or NSG | Check MX records, then `allow-smtp` on `nsg-mail-mx` |
| Outbound queues and retries forever | Platform block on 25 | Path A or Path B above |
| `nc` to port 25 times out | Platform block (drops, not refuses) | Path A or Path B |
| `nc` to port 25 refused | Nothing listening / firewall rejects | Not the platform block — check the destination |
| Mail sends but lands in spam | Reputation, SPF/DKIM/DMARC, or PTR | Step 5 |

## Sources

- [Troubleshoot outbound SMTP connectivity in Azure](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-network/troubleshoot-outbound-smtp-connectivity)
- [Azure Docs mirror](https://docs.azure.cn/en-us/virtual-network/troubleshoot-outbound-smtp-connectivity)

Azure's portal navigation changes from time to time; if a menu path
above does not match what you see, the Microsoft page is authoritative.
