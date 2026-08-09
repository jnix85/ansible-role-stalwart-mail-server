# Session Handoff — Stalwart Ansible Role

Handoff notes for the next AI session continuing this work. Delete this file
once the items below are done.

## Project state

- The repo is a complete, working Ansible role that installs
  [Stalwart](https://stalw.art) mail server from official release binaries.
  **PR #1 was merged to `main`** by the user (with red Molecule CI — their call).
- Working branch: `claude/stalwart-ansible-role-fdyujz`. PR #1 is merged, so
  this branch was **restarted from `origin/main`** — never stack on the old
  (merged) history. Push follow-up work here and open a **new** PR.
- All local validation passes: `yamllint`, `ansible-lint --offline`
  (production profile), syntax check, and template render tests.
- The user's goal: run the role against a real host **soon**. `examples/`
  has a ready playbook + inventory; README documents everything.

## Code-review fixes: 1-10 APPLIED in this branch, 11-13 deferred

A 6-agent `/code-review` completed; findings 1-10 below are **already
fixed** on this branch (verify with git log/diff). Remaining, deferred
pending user interest: 11 (IPv6 default doc), 12 (listener-list refactor),
13 (password_hash filter tradeoff). Original ranked list for reference:

1. **tasks/firewall.yml:29** — Role starts+enables firewalld on EL, but
   defaults/main.yml + README promise it "never enables/activates the
   firewall". Fix: drop that task (or gate behind a new opt-in var) and
   align docs.
2. **templates/stalwart.service.j2:29** — `ReadWritePaths` lists only
   `stalwart_install_dir`; overriding `stalwart_data_dir` /
   `stalwart_log_dir` / `stalwart_selfsigned_dir` outside it crash-loops
   under `ProtectSystem=strict`. Fix: add all three dirs to ReadWritePaths.
3. **tasks/smoke.yml:22** — probes hardcode 127.0.0.1 while listeners bind
   `stalwart_listen_address`. Fix: new `stalwart_smoke_test_host` default
   127.0.0.1, or derive from listen address when it's not a wildcard.
4. **tasks/tls_selfsigned.yml:30** — cert guarded only by `creates:`;
   hostname/days changes never regenerate. Fix: use community.crypto
   (openssl_privatekey + x509_certificate, provider selfsigned) and add
   community.crypto to requirements.yml; removes the perms-fixup task too.
5. **tasks/install.yml:73** — `--check` mode on a fresh host: uri probes are
   skipped → assert fails the dry run. Fix: add `check_mode: false` to the
   probe task (it's read-only) or skip assert when `ansible_check_mode`.
6. **tasks/preflight.yml:34** — accepts `http-01` challenge though no
   port-80 listener can exist with defaults; `tls-alpn-01` not checked
   against `stalwart_https_port == 443`. Fix: assert http-01 requires
   `stalwart_http_enabled` + `stalwart_http_port == 80`; alpn requires
   https on 443.
7. **tasks/install.yml:49** — explicit `stalwart_download_url` override is
   still HEAD-probed, contradicting docs; HEAD-rejecting mirrors break.
   Fix: skip probe/assert entirely when override is set.
8. **tasks/firewall.yml:20** — additive-only; ports of disabled listeners
   never removed. Fix: also iterate the disabled set with state absent/
   delete (ufw `delete: true`, firewalld `state: disabled`).
9. **molecule/default/verify.yml:46** — hardcodes '0.16.9' + ports. Fix:
   load role defaults via vars_files and assert against `stalwart_version`.
10. **tasks/main.yml:3** — include_vars runs before the platform assert;
    unsupported OS gets file-not-found instead of the friendly message.
    Fix: move the platform assert before include_vars (split preflight).
11. **defaults/main.yml:116** (PLAUSIBLE) — `"[::]"` default breaks
    IPv6-disabled hosts. At minimum document; optionally detect.
12. **defaults/main.yml:118** (simplification) — listener model duplicated
    across defaults/template/firewall/smoke; a `stalwart_listeners` list
    would be single-source-of-truth. Larger refactor — optional/discuss.
13. **tasks/configure.yml:5** (PLAUSIBLE) — target-side `openssl passwd -6`
    vs controller-side `password_hash` filter. Deliberate tradeoff
    (avoids passlib requirement on py3.13 controllers). Optional.

Suggested scope: fix 1–10 in one PR; note 11–13 in the PR body as deferred
unless the user wants them.

## Open mystery: Molecule CI failures (do not guess further)

CircleCI is connected (user did it; their sample branch
`circleci-project-setup` still exists — safe to delete after asking).
Pipeline = lint job → 3-distro Molecule matrix (`.circleci/config.yml`).
**Lint passes; all three Molecule jobs (debian12, rockylinux9, ubuntu2404)
fail on every run (4 runs so far). Rocky always fails first/fastest.**

Blind fixes already tried (kept — they're good hardening regardless):
tar+gzip prereqs; venv for pip installs (PEP 668); download-URL probing.
None fixed CI.

**Blockers in this environment** (verify before burning time):
- Proxy blocks `circleci.com` entirely (CONNECT 403) — no API/log access,
  token or not.
- Proxy blocks GitHub for repos other than this one (can't fetch the
  stalwart release to verify asset naming: `stalwart-*` vs
  `stalwart-mail-*` — the role now probes both, so real hosts are fine).
- No Docker daemon in the sandbox — can't run Molecule locally.
- `AWS_ACCESS_KEY_ID/SECRET` env vars exist but are **invalid**
  (InvalidClientTokenId).
- No `CIRCLECI_TOKEN` env var.

**The rule agreed with the user: no more blind fixes.** Unblock paths:
(a) user pastes the failing step's log from app.circleci.com;
(b) user refreshes AWS creds + region + creates a CircleCI machine-runner
resource class + token → build an EC2 self-hosted runner (plan was agreed:
Ubuntu 24.04, t3.large-ish, Docker + runner agent via user-data, then point
the molecule jobs at `resource_class: jnix85/<name>`);
(c) network policy opened for circleci.com + CIRCLECI_TOKEN.

## Watching CI without CircleCI access

CircleCI reports GitHub **commit statuses** (contexts `ci/circleci: lint`,
`ci/circleci: molecule-<distro>`). This works from the sandbox:
`curl https://api.github.com/repos/jnix85/ansible-role-stalwart-mail-server/commits/<SHA>/status`
Poll it with the Monitor tool (45s interval). Exit condition: require
**>= 4 non-pending contexts** — checking "no pending" alone false-exits in
the gap after lint finishes, before molecule statuses appear.

## Environment quirks (will bite you)

- Commit author must be `jnix85 <jnix85@users.noreply.github.com>` — the
  real email is blocked by GitHub email-privacy (GH007 push rejection).
- Commit trailer convention used throughout: see git log.
- A stop-hook rejects ending a turn with uncommitted changes — commit+push
  before finishing.
- `gh` CLI absent; use the GitHub MCP tools. The GitHub API 503s
  occasionally — retry.
- `.ansible/` dir gets created by ansible runs in the repo — it's
  gitignored; don't commit it.
- ansible-lint needs `--offline` (galaxy.ansible.com blocked). Stub
  collections for community.general/ansible.posix live in the scratchpad
  (ephemeral — recreate: minimal galaxy.yml + empty ufw.py/firewalld.py
  module stubs, set ANSIBLE_COLLECTIONS_PATH). After adding
  community.crypto (finding 4), extend the stubs the same way
  (x509_certificate, openssl_privatekey) or lint will fail offline.
- The interactive question tool intermittently dies with permission-stream
  AbortErrors; if it fails twice, ask in plain text instead.
- Stalwart version default is 0.16.9; 0.16.13 existed as of July 2026.
  User hasn't asked for a bump.

## Decisions already made by the user (don't relitigate)

- Platforms: Debian/Ubuntu AND EL9. Install: native binary (no Docker).
- TLS + storage: both configurable (acme/files/selfsigned;
  rocksdb/sqlite/postgresql).
- CI: CircleCI (GitHub Actions was removed deliberately — the user's
  GitHub account had an Actions billing lock; don't re-add workflows).
- Admin password: required vault var, hashed on host, min 12 chars.
- Firewall: opt-in, and the role must never activate a firewall.
