# ssh_automation_account

Creates the dedicated `ansible` automation identity on every node and wires up
certificate-only SSH access for it.

Creates:
- system user `ansible` (locked password, no `wheel` membership, own home dir)
- `/etc/sudoers.d/90-ansible` — `NOPASSWD: ALL`, validated with `visudo -cf` before install
- `/etc/ssh/trusted-user-ca-keys.pem` — Vault SSH CA **public** key only
- `/etc/ssh/auth_principals/ansible` — restricts signed certificates to principal `ansible`
- `/etc/ssh/sshd_config.d/60-homelab-automation.conf` — `Match User ansible` block requiring
  `AuthenticationMethods publickey` (password auth disabled for this account only; the
  global `PasswordAuthentication yes` baseline is untouched)

Safety model for every SSH-affecting change: back up existing files under
`/root/ssh-control-tower-backups`, write the new files, validate with `sshd -t`, `reload`
(never `restart`) sshd, then prove a brand-new independent SSH session still authenticates.
Any failure in that sequence automatically restores the previous files and reloads sshd, then
fails the play loudly instead of leaving a false-positive success.

Never disables `admin` (the break-glass account) and never weakens `PermitRootLogin` or the
global `PasswordAuthentication` setting.
