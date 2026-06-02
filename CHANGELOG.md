# Changelog

All notable changes to AutoFuse will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.1] - 2026-06-12

### Added
- **MCP tool behavior annotations** — all 34 tools now carry `readOnlyHint` / `destructiveHint` / `idempotentHint` annotations per the MCP spec, so clients can auto-approve the 18 read-only tools and reserve confirmation prompts for destructive ones. Known engine error codes return a `hint:` line pointing the agent at the next step (e.g. `host_key_mismatch` → run `learn_host_key`).
- **Agent-friendly CLI commands** (`cli/autofuse`, v4.1) — `connect <ws>` pings the workstation, sends Wake-on-LAN if it's off, then mounts all of its disks; `json [status|health|list|disks <ws>]` emits machine-readable JSON with stable shapes (`[{workstation, disk, status, mount_point}]`, `[{name, lan_ip, vpn_ip, disks[], mac}]`, `[{letter, label, remote_path}]`); `raw <cmd> [...]` gives direct access to every `mount.sh` engine subcommand, including ones without a friendly wrapper.
- **Architecture conventions** in `CONTRIBUTING.md` — engine-as-source-of-truth, exit-code-as-signal, stable output strings, energy discipline.
- **Real app screenshots** in the README (menu bar, Add Computer, Preferences) and per-client MCP configuration snippets (Cursor/Windsurf/Cline, Codex CLI, Gemini CLI, skill-based agents).
- **MCP Server** (`mcp-server/`) — Model Context Protocol server for Claude Desktop, Claude Code, and other MCP clients. Now exposes **34 tools** (6 intent-level composites like `quick_connect`/`fix_it`/`locate` + granular mount/unmount/wake/scan/probe/health/panic recovery + unrestricted `run_local_shell`/`run_remote_shell` escape hatches). Installable with `./install.sh`. Zero shell injection risk via `execFile` array args. Tool descriptions follow a consistent verb+when+returns+errors template so LLM callers select the right tool accurately.
- **Sparkle auto-update** (optional, conditional) — when `brew install sparkle` is present, AutoFuse bundles Sparkle.framework and adds a "Check for Updates…" menu item. All Sparkle code guarded by `#if __has_include(<Sparkle/Sparkle.h>)` so it compiles cleanly with or without Sparkle. See `docs/SPARKLE-SETUP.md` and `appcast.xml`.
- **SMB protocol support** — `discover.sh scan-network` and `probe-host` now also check port 445; protocol auto-suggested in workstation config (`protocol: "smb"` + `smb_share: "C$"`). Complements SSHFS for Windows file shares.
- **Multi-endpoint machine identity (SSH host key)** — three new commands: `learn-host-key <ws>` captures the remote SHA256 fingerprint, `verify-host-key <ws>` checks it against every endpoint, and `pick-endpoint <ws>` prints the best reachable endpoint (host-key-verified when a fingerprint is stored). Config schema adds optional `additional_ips[]` and `host_key_sha256` fields; mDNS `<name>.local` is automatically tried as a final fallback. Lets AutoFuse reconnect to the *same* machine across different networks (Studio WiFi, home WiFi, VPN, Tailscale) even when IPs change. When a fingerprint is stored, `_do_mount` now uses it transparently to pick a verified endpoint and refuses to mount if no endpoint's current key matches — protects against silent connections to a rotated or impostor host. First successful mount of a new workstation auto-captures the fingerprint (TOFU), so users get multi-endpoint identity + rotation protection without running any extra command. The Add/Edit Workstation dialog now exposes a multi-line "Additional IPs" field (Tailscale, mDNS, extra routes) and a read-only "Host Key" display with a "Re-learn" button for post-reinstall recovery — no more config.json hand-editing.
- **Smart endpoint memory** — `_pick_endpoint` now caches the last-working endpoint per workstation at `~/.config/autofuse/.endpoint-cache/<ws>` (TTL 1 hour). On repeated mounts from the same network, the cached endpoint is tried first, skipping up to 4 × 2s `_reachable` probes plus ssh-keyscan overhead on wrong endpoints. Falls back to full iteration on cache miss / staleness / unreachable-cached / key-mismatch. New CLI: `endpoint-cache-show [ws]` and `endpoint-cache-clear [ws]`.
- **Endpoint-switch notifications** — when `_pick_endpoint` falls through to a different endpoint than the one cached (e.g. LAN → Tailscale because you left the office), it drops an event file at `~/.config/autofuse/.events/switch-<ts>` that the menu-bar app consumes and posts a native `UNUserNotification`: "ml-workstation reconnected — Switched to 192.168.1.100 via en0 (was 172.16.0.100)". The new-endpoint interface is resolved via `/sbin/route` so the user immediately sees the network-context change, not just a bare IP. Drain runs on a background queue with 2s route-lookup timeout — no UI stalls during network flaps.
- **Auto-exclude from Spotlight / Time Machine** — every successful mount now calls `mdutil -i off` + `tmutil addexclusion` on the mount point. Idempotent and silent; wired into all four mount success paths (LAN / VPN / WoL-LAN / WoL-VPN). Resolves two prior UX pitfalls that were documented as manual fixes.
- `panic-unmount-all` and `panic-check` commands in mount.sh for aggressive stale-mount recovery on network loss
- Network loss detection in main.m: pings workstations on network change; if none reachable, triggers panic-unmount to prevent Finder/app hangs
- Faster stale detection: `_alive()` uses 2s hard timeout (was 3s)
- GitHub publication assets: `.gitignore`, `CONTRIBUTING.md`, `SECURITY.md`, `.github/workflows/` (CI + release), issue templates

### Fixed
- `health-json` command now emits valid JSON array even when no mounts active
- Primary disk flag now preserved correctly when editing a workstation via the dialog
- `probe-host` disk output: size (e.g. `(421.8/464.8)`) now appended to label, not corrupted into `remote_path`
- User config (`~/.config/autofuse/config.json`) now takes priority over bundle config — fixes lost workstations after app updates
- MCP server parsers rewritten (14 tools) to use pipe-delimited format matching mount.sh output instead of JSON.parse
- `_ssh_ok` and `_ensure_key_unlocked` timeouts (`alarm 8 + ConnectTimeout=5`) were too tight for ~1s RTT links (Tailscale overseas, WifiMan distant sites, satellite). Raised to `alarm 25 + ConnectTimeout=15` — covers ~4-8 RTT of SSH handshake at 1s/RTT while still failing fast (25s) on truly dead hosts.
- `ssh_options.connect_timeout` config key was silently ignored by the sshfs launcher. Now applied as `-o ConnectTimeout={value, default 30}` so users on high-latency VPNs can tune the initial mount window without patching code.
- `build.sh`: Info.plist is now generated BEFORE the MCP bundle step, and `npm install` for the MCP server has a 60s hard timeout via `perl alarm`. Previously a stalled npm (slow Wi-Fi) could abort the script before reaching Info.plist creation, leaving the bundle without a CFBundleIdentifier — the app would then fail to launch with "UNUserNotificationCenter could not determine bundleIdentifier".
- `discover.sh probe-host` now early-exits with `error:probe_failed:host_unreachable` when both port 22 and port 445 are closed, cutting unreachable-host probe time from 14s (2× SSH ConnectTimeout=5s + 2× fallback) to ~4s (2× nc timeout 2s).
- `discover.sh scan-network` now filters multicast (`224.0.0.0/4`), broadcast (`255.255.255.255`), and their MAC equivalents (`ff:ff:ff:ff:ff:ff`, `01:00:5e:*`) from ARP cache results — previously produced rows like `224.0.0.251|mdns.mcast.net|1:0:5e:0:0:fb` that confused LLM callers.
- `discover.sh detect-vpn` now detects Unifi WifiMan SD-WAN by process match (`pgrep -if wifiman`) — the bundled WireGuard is not visible to the `wg` CLI, so utun interfaces were previously labeled generic `vpn` instead of `wifiman`.
- `status-all` command parallelized via process substitution (`< <(_json_raw list_workstations)`) instead of a pipe — pipes run the `while` loop in a subshell that loses track of backgrounded forks, breaking `wait` semantics.

### Changed
- **License changed from MIT to PolyForm Shield 1.0.0** to allow commercial use while preventing competing forks
- README badges updated to reflect new license
- Menu bar opens immediately from cached state, with async refresh in background — previously blocked 2-6s on slow networks during `status-all`.
- Status log is state-transition-only (per-disk cache at `~/.config/autofuse/.status-cache/<ws>__<letter>`) — eliminates polling flood in `autofuse.log`.
- Idle-energy discipline: mount state is polled natively via `getmntinfo()` (no per-poll subprocesses), poll/heal timers stretch on an adaptive cadence when nothing is changing, and the engine defaults SSH keepalive to `ServerAliveInterval=30`.

### Security
- Untrusted input (remote-host output, user config values) never reaches an interpreter as source — values are passed via `argv` (`python3 -c '…' "$value"`), not string-interpolated into code.
- Stale-mount recovery kills sshfs by verified per-PID match against the exact mount point, instead of a broad `pkill -f "sshfs.*<pattern>"` that could hit unrelated processes.
- All `NSWindow` instances use `releasedWhenClosed = NO`, fixing a use-after-free when dialogs are reopened.

## [4.0.0] - 2026-04-08

### Added

- Initial public release
- Native macOS menu bar app (304KB Objective-C binary)
- Auto-discovery: network scan, SSH config import, host probe (OS/MAC/disks)
- Wake-on-LAN with MAC auto-detection
- Auto-heal stale mounts on sleep/wake and network change
- Setup Wizard for first-time users
- FUSE-T and macFUSE support with automatic detection
- CLI tool (`autofuse` command) for terminal users and scripting
- Connection health dashboard showing latency and throughput per mount
- Team config export/import for easy onboarding
- Preferences window with SSH key, cache, and connection settings
- Native macOS notifications for connection events
- Multi-computer support with multiple disks per computer
- Secure configuration with SSH keys, no stored passwords
- Config file at `~/.config/autofuse/config.json` with 0600 permissions
- Activity logging to `~/.config/autofuse/autofuse.log`
- Zero CPU usage when idle

## Future Roadmap

### Planned for 4.2.0

- [ ] Keychain integration for SSH passphrases
- [ ] Bookmark support in Finder sidebar
- [ ] Performance metrics dashboard
- [ ] Support for additional SSH key types
- [ ] Batch operations (mount/unmount multiple at once)

### Planned for 4.3.0

- [ ] Integration with macOS Keychain
- [ ] WebDAV as alternative to SSHFS
- [ ] Time Machine backup support over remote mounts
- [ ] Advanced network diagnostics
