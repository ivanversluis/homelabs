# SSH Agent Setup (WSL)

## Overview

Uses `keychain` to manage `ssh-agent` across all terminals in a WSL session. The passphrase is entered **once per WSL session** — all subsequent terminal tabs connect silently to the same running agent.

## How It Works

1. On shell startup, `~/.zshrc` runs `eval "$(keychain --eval --quiet id_ed25519)"`
2. `keychain` checks if an agent is already running with the key loaded
3. If yes: silently exports `SSH_AUTH_SOCK`/`SSH_AGENT_PID` into the new shell
4. If no: starts a fresh agent, prompts for the passphrase once, then caches it
5. All subsequent terminals in the same WSL session skip the prompt entirely

## WSL Session Lifetime Limitation

WSL is a Linux VM managed by Windows. When all WSL processes exit, Windows terminates the VM after ~8 seconds — killing the ssh-agent with it. This means:

| Scenario | Passphrase required? |
|---|---|
| New terminal tab (WSL still running) | No |
| VS Code reopened, WSL still alive | No |
| WSL was shut down between sessions | Yes — once |

This is a hard WSL constraint. The agent cannot survive a WSL restart without bridging to the **Windows OpenSSH Authentication Agent** service (see below).

## Files

| File | Purpose |
|------|---------|
| `~/.zshrc` | Runs `keychain` eval before p10k instant prompt |
| `~/.ssh/agent-setup.sh` | Legacy fallback script (kept for manual use) |
| `~/.keychain/` | keychain's PID/socket cache (auto-managed) |

## Installation

```bash
sudo pacman -S keychain
```

## Manual Operations

```bash
# Check loaded keys
ssh-add -l

# Force re-add key (prompts for passphrase)
keychain --eval id_ed25519

# Clear all keys and stop agent
keychain --clear

# Kill the agent entirely
keychain --stop all
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Passphrase asked every terminal | keychain not installed — `sudo pacman -S keychain` |
| `Could not open connection to auth agent` | Run `eval "$(keychain --eval id_ed25519)"` manually |
| keychain line in zshrc has no effect | Confirm it is ABOVE the `p10k-instant-prompt` block |
| Passphrase asked after reopening VS Code | WSL restarted — expected; enter once and all tabs are covered |

## Optional: True Persistence via Windows SSH Agent

To avoid the passphrase prompt even after WSL restarts, bridge the Windows OpenSSH Authentication Agent service to WSL:

1. **On Windows** (PowerShell as Admin):
   ```powershell
   Set-Service ssh-agent -StartupType Automatic
   Start-Service ssh-agent
   ssh-add $env:USERPROFILE\.ssh\id_ed25519   # enter passphrase once
   ```
2. **In WSL**, install `socat` and `npiperelay`:
   ```bash
   sudo pacman -S socat
   # npiperelay.exe must be on the Windows PATH (download from GitHub releases)
   ```
3. **Replace the keychain line in `~/.zshrc`** with a socket bridge:
   ```bash
   export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
   if ! ss -a | grep -q "$SSH_AUTH_SOCK"; then
       rm -f "$SSH_AUTH_SOCK"
       (setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
           EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent" &)
   fi
   ```
   After this, the Windows agent holds the key and the WSL socket bridges to it.

## Security Considerations

- The agent socket is only accessible by the owning user (0600 permissions)
- Never forward the agent to untrusted hosts (`ssh -A` only to your own machines)
- The Windows SSH Agent bridge exposes the Windows-managed key store to WSL processes
