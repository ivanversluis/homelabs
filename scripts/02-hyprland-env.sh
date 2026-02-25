#!/usr/bin/env bash
set -euo pipefail

# ---
# Mischa-style Arch + Hyprland workstation layer
# - Hyprland + waybar + wofi + hyprpaper + mako
# - Alacritty, tmux, Neovim, VS Code (OSS)
# - Zsh + autosuggestions + syntax highlighting + Powerlevel10k
# - Obsidian for notes (with Excalidraw plugin inside Obsidian)
# - Wacom support
# - Docker for dev-container workflows
# ---

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root (e.g. via sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "Could not determine non-root user (SUDO_USER empty)."
  echo "Re-run as: sudo TARGET_USER=<username> $0"
  exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
  echo "User '$TARGET_USER' does not exist." >&2
  exit 1
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "Configuring Mischa-style Hyprland + zsh + Obsidian setup for user: $TARGET_USER ($USER_HOME)"
sleep 2

# -------------------------------------------------------------
# Packages
# -------------------------------------------------------------

echo "[*] Installing packages via pacman..."
pacman -Syu --noconfirm

pacman -S --needed --noconfirm \
  # Hyprland + ecosystem
  hyprland waybar wofi hyprpaper mako \
  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  # terminal + tools
  alacritty neovim tmux git \
  # editor/IDE
  code \
  # fonts (used in configs)
  ttf-jetbrains-mono-nerd \
  # audio stack (pipewire)
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
  # clipboard / screenshots (Wayland)
  wl-clipboard grim slurp \
  # browser (for iCloud web app, etc.)
  firefox \
  # Wacom support
  libwacom xf86-input-wacom \
  # session / permissions for Hyprland
  seatd \
  # containers for dev-container workflows
  docker docker-compose \
  # shell + power tools
  zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting \
  # note-taking (OneNote replacement)
  obsidian

# -------------------------------------------------------------
# Services & groups
# -------------------------------------------------------------

echo "[*] Enabling services and adding user to groups..."
systemctl enable --now seatd.service
systemctl enable --now docker.service

usermod -aG seat,input,video,docker "$TARGET_USER"

# -------------------------------------------------------------
# User configs (Hyprland stack)
# -------------------------------------------------------------

echo "[*] Creating user configuration for Hyprland stack..."
sudo -u "$TARGET_USER" mkdir -p \
  "$USER_HOME/.config/hypr" \
  "$USER_HOME/.config/waybar" \
  "$USER_HOME/.config/wofi" \
  "$USER_HOME/.config/alacritty"

cat > "$USER_HOME/.config/hypr/hyprland.conf" <<'EOF'
# Basic Hyprland config, close to upstream defaults, tuned for:
# - SUPER as main modifier
# - waybar + wofi + hyprpaper + mako
# - Alacritty as terminal

monitor=,preferred,auto,1

$mod = SUPER

# Autostart
exec-once = hyprpaper
exec-once = waybar
exec-once = mako

input {
    kb_layout = us
    follow_mouse = 1

    sensitivity = 0

    touchpad {
        natural_scroll = true
    }

    tablet {
        # For Wacom on Hyprland:
        # - plug tablet
        # - run `hyprctl devices` to see device name under "Tablets:"
        # - add a device: block below (see commented example).
    }
}

# Example per-device tablet mapping:
# device:wacom-intuos-bt-m-pen {
#     transform = 0
#     output = HDMI-A-1
# }

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = 0xff89b4fa
    col.inactive_border = 0xff44475a
    layout = dwindle
}

decoration {
    rounding = 8
    blur {
        enabled = true
        size = 8
        passes = 1
    }
}

animations {
    enabled = true
    bezier = easeOut, 0.05,0.9,0.1,1.0
    animation = windows, 1, 7, easeOut, popin
    animation = windowsOut, 1, 7, easeOut, popin
    animation = border, 1, 10, easeOut
    animation = fade, 1, 7, easeOut
    animation = workspaces, 1, 6, easeOut, slide
}

bind = $mod, Return, exec, alacritty
bind = $mod, Q, killactive,
bind = $mod SHIFT, Q, exit,
bind = $mod, E, exec, firefox
bind = $mod, D, exec, wofi --show drun

bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

bind = $mod SHIFT, H, movewindow, l
bind = $mod SHIFT, L, movewindow, r
bind = $mod SHIFT, K, movewindow, u
bind = $mod SHIFT, J, movewindow, d

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9
bind = $mod, 0, workspace, 10

bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod SHIFT, 6, movetoworkspace, 6
bind = $mod SHIFT, 7, movetoworkspace, 7
bind = $mod SHIFT, 8, movetoworkspace, 8
bind = $mod SHIFT, 9, movetoworkspace, 9
bind = $mod SHIFT, 0, movetoworkspace, 10

bind = $mod, F, fullscreen, 0
bind = $mod SHIFT, F, togglefloating,

bind = $mod, R, submap, resize

submap = resize
binde = , H, resizeactive, -20 0
binde = , L, resizeactive, 20 0
binde = , K, resizeactive, 0 -20
binde = , J, resizeactive, 0 20
bind = , escape, submap, reset
submap = reset

bind = $mod, S, exec, grim -g "$(slurp)" "$HOME/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png"
EOF

sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/.config/hypr"
cat > "$USER_HOME/.config/hypr/hyprpaper.conf" <<'EOF'
preload = /usr/share/backgrounds/archlinux/archlinux-simplyblack.png
wallpaper = ,/usr/share/backgrounds/archlinux/archlinux-simplyblack.png
EOF

cat > "$USER_HOME/.config/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "modules-left": ["workspaces", "window"],
  "modules-center": [],
  "modules-right": ["cpu", "memory", "pulseaudio", "clock"],
  "clock": {
    "format": "{:%Y-%m-%d %H:%M}"
  }
}
EOF

cat > "$USER_HOME/.config/waybar/style.css" <<'EOF'
* {
  border: none;
  border-radius: 0;
  font-family: "JetBrainsMono Nerd Font", monospace;
  font-size: 11px;
  min-height: 0;
}

window#waybar {
  background-color: rgba(40, 42, 54, 0.9);
  color: #f8f8f2;
}
EOF

cat > "$USER_HOME/.config/wofi/config" <<'EOF'
show=drun
prompt=Run:
term=alacritty
hide_scroll=true
allow_images=false
EOF

cat > "$USER_HOME/.config/alacritty/alacritty.toml" <<'EOF'
[window]
decorations = "none"
opacity = 0.95

[font]
normal = { family = "JetBrainsMono Nerd Font", style = "Regular" }
size = 11.0

[colors.primary]
background = "#282a36"
foreground = "#f8f8f2"
EOF

# -------------------------------------------------------------
# Zsh + Powerlevel10k
# -------------------------------------------------------------

echo "[*] Setting up zsh + power tools..."

# Clone Powerlevel10k into user's home (no AUR dependency)
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/.local/share"
if [[ ! -d "$USER_HOME/.local/share/powerlevel10k" ]]; then
  sudo -u "$TARGET_USER" git clone --depth=1 \
    https://github.com/romkatv/powerlevel10k.git \
    "$USER_HOME/.local/share/powerlevel10k"
fi

# Minimal .zshrc tailored for autosuggestions + syntax highlighting + P10k.
# If you already manage dotfiles, you can overwrite this later.
cat > "$USER_HOME/.zshrc" <<'EOF'
export EDITOR="nvim"
export VISUAL="nvim"

HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_FIND_NO_DUPS \
       INC_APPEND_HISTORY SHARE_HISTORY

autoload -Uz compinit
compinit

# Autosuggestions & syntax highlighting (Arch package paths)
if [[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

if [[ -r /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# Powerlevel10k prompt
if [[ -r "$HOME/.local/share/powerlevel10k/powerlevel10k.zsh-theme" ]]; then
  source "$HOME/.local/share/powerlevel10k/powerlevel10k.zsh-theme"
fi
[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

# Aliases
alias ll='ls -lh --color=auto'
alias la='ls -lah --color=auto'
alias gs='git status -sb'

# Optionally auto-start tmux (comment out if you don't want this)
if [[ -z "$TMUX" ]] && command -v tmux >/dev/null 2>&1; then
  tmux attach -t main || tmux new -s main
fi
EOF

# Make zsh default shell for target user
chsh -s /usr/bin/zsh "$TARGET_USER"

chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config" "$USER_HOME/.zshrc"

echo
echo "[*] Done."
echo "Next steps:"
echo "  - Log in as $TARGET_USER on a TTY and run: Hyprland"
echo "  - First time you start a zsh session, Powerlevel10k will offer a config wizard (p10k configure)."
echo "  - For Wacom: plug it in, run 'hyprctl devices', then add a device: block in ~/.config/hypr/hyprland.conf."
echo "  - For notes: launch Obsidian, then in Settings -> Community plugins -> Browse, install 'Excalidraw' plugin."
echo
