# AutoFuse for Linux

The macOS menu-bar app doesn't run on Linux, but its **engine, CLI, MCP server,
and a GTK GUI do** — because all the mount logic lives in one shared bash engine
and everything else is a thin front-end over it. On Linux you get:

- **`autofuse`** — the CLI (mount / unmount / connect / wake / status / heal)
- **`autofuse-gui`** — a small GTK window listing every machine with its IP and
  mount status, and buttons to mount/unmount/connect each. No system-tray host
  required, so it works on Hyprland, sway, i3, GNOME, KDE — anything.
- **`autofuse-wofi`** — a wofi/rofi quick picker you bind to a key (ideal for
  tiling WMs)
- **MCP server** — the same 34 tools, so Claude / agents can drive it

## Requirements

- `sshfs` + `fuse3` (the actual mount backend — native on Linux)
- `openssh`, `python3`
- `gtk4` + `python-gobject` (for the GUI)
- `wofi` or `rofi` (optional, for the quick picker)
- `nodejs` + `npm` (optional, for the MCP server)

On Arch:

```bash
sudo pacman -S --needed sshfs fuse3 openssh python gtk4 python-gobject wofi
```

## Install

From the repo root:

```bash
./linux/install.sh          # installs into ~/.local (no root for the app)
./linux/install.sh --deps   # also installs missing system packages via pacman
./linux/install.sh --mcp    # also builds the MCP server and prints the register cmd
```

Make sure `~/.local/bin` is on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Use

```bash
autofuse add                  # add a machine: name, IP/host, SSH user, disks
autofuse                      # status of all mounts
autofuse connect myserver     # wake (if asleep) + mount all its disks
autofuse mount myserver /     # mount one path
autofuse unmount myserver
autofuse-gui                  # open the window
```

A "disk" on a Linux/remote box is just a remote path — e.g. `/`, `/home`, or
`/srv`. For Windows hosts it's `/C:/`, `/D:/`, etc. Mounts appear under
`~/workstation/<name>/...`.

### Hyprland keybind for the picker

Add to `~/.config/hypr/hyprland.conf`:

```
bind = $mainMod, M, exec, autofuse-wofi
```

### MCP server (Claude / agents)

```bash
./linux/install.sh --mcp
# then, as printed:
claude mcp add autofuse -e AUTOFUSE_SCRIPTS=$HOME/.local/share/autofuse -- \
    node /path/to/autofuse/mcp-server/dist/index.js
```

The `AUTOFUSE_SCRIPTS` env var points the MCP server at the installed engine.

## How it maps to macOS

| macOS | Linux |
|-------|-------|
| FUSE-T / macFUSE | `fuse3` + `sshfs` |
| menu-bar app (`main.m`) | `autofuse-gui` (GTK) + `autofuse-wofi` |
| `diskutil unmount` | `fusermount -u` |
| same `mount.sh` / `discover.sh` engine | same engine (OS-branched internally) |
| same MCP server | same MCP server |

## Uninstall

```bash
rm -f ~/.local/bin/autofuse ~/.local/bin/autofuse-gui ~/.local/bin/autofuse-wofi
rm -rf ~/.local/share/autofuse
rm -f ~/.local/share/applications/autofuse.desktop
# config + known_hosts (optional): rm -rf ~/.config/autofuse
```
