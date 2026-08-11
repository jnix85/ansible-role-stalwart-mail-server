# Example project: deploy Stalwart with this role

A ready-to-copy Ansible project layout consuming the
`jnix85.stalwart_mail_server` role:

```
examples/
├── ansible.cfg                      # inventory + roles path
├── requirements.yml                 # role (from git) + collections
├── site.yml                         # entry point
├── playbooks/
│   └── mailserver.yml               # binds the role to the group
└── inventory/
    ├── hosts.yml                    # your hosts
    └── group_vars/
        └── mailservers/
            ├── vars.yml             # all Stalwart settings
            └── vault.yml.example    # secret template → vault.yml
```

## Usage

```sh
cp -r examples ~/mail-infra && cd ~/mail-infra

# 1. Install the role and collections
ansible-galaxy install -r requirements.yml

# 2. Point the inventory at your server
$EDITOR inventory/hosts.yml

# 3. Create the vault with your admin password
cd inventory/group_vars/mailservers
cp vault.yml.example vault.yml
$EDITOR vault.yml
ansible-vault encrypt vault.yml
cd -

# 4. Review settings (TLS mode, storage, listeners)
$EDITOR inventory/group_vars/mailservers/vars.yml

# 5. Deploy
ansible-playbook site.yml --ask-vault-pass
```

A green run means a working server (the role's built-in smoke test
verifies the service, listeners, and health endpoint). Then open
`https://<your-host>` and log in as `admin` to add domains and accounts;
Stalwart shows the exact SPF/DKIM/DMARC DNS records to publish.

For a lab box without public DNS, set `stalwart_tls_mode: selfsigned`
in `vars.yml` and drop the `stalwart_acme_*` lines.
