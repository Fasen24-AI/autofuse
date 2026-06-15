#!/usr/bin/env bash
# AutoFuse — Linux installer (Arch-first, works on any distro).
#
# Installs into the user's home (no root needed for the app itself):
#   engine  → ~/.local/share/autofuse/{mount.sh,discover.sh}
#   CLI     → ~/.local/bin/autofuse        (SCRIPT_DIR pinned to the engine dir)
#   GUI     → ~/.local/bin/autofuse-gui    (GTK window)
#   picker  → ~/.local/bin/autofuse-wofi   (wofi/rofi quick menu)
#   desktop → ~/.local/share/applications/autofuse.desktop
#   config  → ~/.config/autofuse/config.json (created empty if missing)
#
# System packages (sshfs, fuse, gtk4, …) need root: pass --deps to install them
# via pacman, or run the printed command yourself. Safe to re-run (idempotent).
#
# Usage:
#   ./install.sh            # install app into ~/.local, check deps
#   ./install.sh --deps     # also install missing system packages (sudo pacman)
#   ./install.sh --mcp      # also build the MCP server for Claude/agents
set -euo pipefail

WITH_DEPS=0
WITH_MCP=0
for arg in "$@"; do
    case "$arg" in
        --deps) WITH_DEPS=1 ;;
        --mcp)  WITH_MCP=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBEXEC="$HOME/.local/share/autofuse"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
CFG_DIR="$HOME/.config/autofuse"

say()  { printf '\033[0;36m==>\033[0m %s\n' "$1"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$1"; }

# ─── 1. System dependencies ──────────────────────────────────────────────────
say "Checking system dependencies"
missing=()
command -v sshfs   >/dev/null 2>&1 || missing+=(sshfs)
command -v ssh     >/dev/null 2>&1 || missing+=(openssh)
command -v python3 >/dev/null 2>&1 || missing+=(python)
command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || missing+=(fuse3)
# GUI deps (gtk4 + gobject bindings); detected via python import.
python3 -c 'import gi; gi.require_version("Gtk","4.0")' >/dev/null 2>&1 \
    || missing+=(gtk4 python-gobject)

if [ "${#missing[@]}" -eq 0 ]; then
    ok "all core dependencies present"
else
    warn "missing: ${missing[*]}"
    if command -v pacman >/dev/null 2>&1; then
        if [ "$WITH_DEPS" -eq 1 ]; then
            say "Installing missing packages (sudo pacman)"
            sudo pacman -S --needed --noconfirm "${missing[@]}"
        else
            warn "install them with:  sudo pacman -S --needed ${missing[*]}"
            warn "(or re-run this script with --deps)"
        fi
    else
        warn "non-Arch system: install the equivalents of: ${missing[*]}"
    fi
fi
# Optional: wofi/rofi for the quick picker.
command -v wofi >/dev/null 2>&1 || command -v rofi >/dev/null 2>&1 \
    || warn "for the quick picker (autofuse-wofi) install: wofi  (or rofi)"

# ─── 2. Install engine + CLI + GUI + picker ──────────────────────────────────
say "Installing AutoFuse into ~/.local"
mkdir -p "$LIBEXEC" "$BIN" "$APPS" "$CFG_DIR"

install -m 0755 "$REPO/mount.sh"    "$LIBEXEC/mount.sh"
install -m 0755 "$REPO/discover.sh" "$LIBEXEC/discover.sh"
ok "engine → $LIBEXEC"

# CLI: pin the engine location (mirrors the Homebrew formula's inreplace).
sed "s|SCRIPT_DIR_PLACEHOLDER|$LIBEXEC|" "$REPO/cli/autofuse" > "$BIN/autofuse"
chmod 0755 "$BIN/autofuse"
ok "CLI → $BIN/autofuse"

install -m 0755 "$SCRIPT_DIR/autofuse-gui.py" "$BIN/autofuse-gui"
install -m 0755 "$SCRIPT_DIR/autofuse-wofi"   "$BIN/autofuse-wofi"
ok "GUI + picker → $BIN"

install -m 0644 "$SCRIPT_DIR/autofuse.desktop" "$APPS/autofuse.desktop"
ok "desktop entry → $APPS"

# ─── 3. Config (never overwrite an existing one) ─────────────────────────────
if [ ! -f "$CFG_DIR/config.json" ]; then
    if [ -f "$REPO/config.json" ]; then
        install -m 0600 "$REPO/config.json" "$CFG_DIR/config.json"
    else
        cat > "$CFG_DIR/config.json" <<'JSON'
{
  "mount_base": "~/workstation",
  "poll_interval": 30,
  "heal_interval": 120,
  "heal_on_network_change": true,
  "ssh_options": {
    "cipher": "aes128-gcm@openssh.com",
    "compression": 0,
    "keepalive_count": 3,
    "keepalive_interval": 30
  },
  "workstations": []
}
JSON
        chmod 0600 "$CFG_DIR/config.json"
    fi
    ok "created $CFG_DIR/config.json"
else
    ok "kept existing $CFG_DIR/config.json"
fi

# ─── 4. Optional: MCP server for Claude / agents ─────────────────────────────
if [ "$WITH_MCP" -eq 1 ]; then
    if command -v npm >/dev/null 2>&1; then
        say "Building MCP server"
        ( cd "$REPO/mcp-server" && npm install --silent && npm run build --silent )
        ok "MCP server built at $REPO/mcp-server/dist/index.js"
        echo
        say "Register it with your agent (engine pinned via AUTOFUSE_SCRIPTS):"
        echo "  claude mcp add autofuse -e AUTOFUSE_SCRIPTS=$LIBEXEC -- node $REPO/mcp-server/dist/index.js"
    else
        warn "npm not found — install nodejs+npm, then re-run with --mcp"
    fi
fi

# ─── 5. PATH check + next steps ──────────────────────────────────────────────
echo
case ":$PATH:" in
    *":$BIN:"*) : ;;
    *) warn "~/.local/bin is not on your PATH — add to your shell rc:"
       warn '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

say "Done. Next steps:"
echo "  autofuse add          # add a machine (name, IP/host, user, disks)"
echo "  autofuse              # show status"
echo "  autofuse connect NAME # wake (if needed) + mount a machine"
echo "  autofuse-gui          # open the window"
echo "  autofuse-wofi         # quick picker (bind to a key in Hyprland)"
