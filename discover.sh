#!/bin/bash
# AutoFuse — Auto-Discovery Script
# Usage: discover.sh <command> [args]
# Commands: scan-network, scan-tailscale, import-ssh-config, probe-host, detect-vpn
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# OS portability: macOS uses route/ifconfig/arp/ipconfig; Linux uses iproute2.
AF_OS="$(uname -s)"

# Neighbour/ARP table, one entry per line. macOS: `arp -a`; Linux: `ip neigh`.
_neighbour_table() {
    if [ "$AF_OS" = "Darwin" ]; then arp -a 2>/dev/null
    else ip neigh 2>/dev/null; fi
}

# Dedicated known_hosts for AutoFuse
AF_KNOWN_HOSTS="$HOME/.config/autofuse/known_hosts"
mkdir -p "$(dirname "$AF_KNOWN_HOSTS")" 2>/dev/null
# Migrate old known_hosts if new one doesn't exist yet
if [ ! -f "$AF_KNOWN_HOSTS" ] && [ -f "$HOME/.config/workstationmount/known_hosts" ]; then
    cp "$HOME/.config/workstationmount/known_hosts" "$AF_KNOWN_HOSTS"
fi

# Portable timeout (macOS has no `timeout` command)
_timeout() {
    local secs="$1"; shift
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@" 2>/dev/null
}

# ─── scan-network ──────────────────────────────────────────────────────────

# Discover reachable hosts on the local /24 subnet. The flow is:
#   1. Identify the primary interface via `route -n get default` (fallback en0).
#   2. Prime the ARP cache with a broadcast ping so we get MAC addresses for
#      hosts that haven't been talked to recently — without this, `arp -a`
#      only knows about hosts in the current conversation set.
#   3. For each host in ARP, probe TCP/22 (SSH) AND TCP/445 (SMB) in parallel
#      with 2-second timeouts. Both flags are reported so the GUI can
#      suggest the right protocol at add-workstation time.
# Output format (pipe-delimited, one host per line):
#   ip|hostname|mac|ssh_open|smb_open
# Sort order puts ssh-capable hosts first, then smb-capable hosts. Consumed
# by the Add Workstation dialog and by MCP's `scan_network` tool.
_scan_network() {
    # Get local subnet from primary interface
    local iface local_ip
    if [ "$AF_OS" = "Darwin" ]; then
        iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
        [ -z "$iface" ] && iface="en0"
        local_ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    else
        iface="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
        [ -z "$iface" ] && iface="eth0"
        local_ip="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    fi

    # Populate the neighbour cache with a quick broadcast ping (non-blocking)
    if [ -n "$local_ip" ]; then
        local prefix="${local_ip%.*}"
        if [ "$AF_OS" = "Darwin" ]; then
            ping -c 1 -t 1 "${prefix}.255" >/dev/null 2>&1 &
        else
            ping -c 1 -W 1 -b "${prefix}.255" >/dev/null 2>&1 &
        fi
        local ping_pid=$!
        sleep 1
        kill "$ping_pid" 2>/dev/null
    fi

    # Parse the neighbour/ARP cache for known hosts
    local tmpfile
    tmpfile="$(mktemp /tmp/wm_scan.XXXXXX)"

    _neighbour_table | while IFS= read -r line; do
        local ip hostname mac
        if [ "$AF_OS" = "Darwin" ]; then
            # "? (192.168.1.5) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
            ip="$(echo "$line" | sed -n 's/.*(\([0-9.]*\)).*/\1/p')"
            echo "$line" | grep -q "incomplete" && continue
            mac="$(echo "$line" | awk '{print $4}')"
            hostname="$(echo "$line" | awk '{print $1}')"
            [ "$hostname" = "?" ] && hostname=""
        else
            # "ip neigh": "192.168.1.5 dev eth0 lladdr aa:bb:cc:dd:ee:ff REACHABLE"
            ip="$(echo "$line" | awk '{print $1}')"
            echo "$line" | grep -qE 'FAILED|INCOMPLETE' && continue
            mac="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')"
            hostname=""
        fi
        [ -z "$ip" ] && continue

        # Filter multicast (224.0.0.0/4) and broadcast addresses.
        case "$ip" in
            22[4-9].*|23[0-9].*|255.255.255.255) continue ;;
        esac

        # Filter broadcast / multicast MACs.
        case "$mac" in
            ""|ff:ff:ff:ff:ff:ff|FF:FF:FF:FF:FF:FF) continue ;;
            1:0:5e:*|01:00:5e:*) continue ;;
        esac

        echo "${ip}|${hostname}|${mac}" >> "$tmpfile"
    done

    # Check SSH port 22 and SMB port 445 in parallel (max 10 seconds total)
    local pids=()
    local results_file
    results_file="$(mktemp /tmp/wm_results.XXXXXX)"

    while IFS='|' read -r ip hostname mac; do
        [ -z "$ip" ] && continue
        (
            local ssh_open="no"
            local smb_open="no"
            
            if _timeout 2 nc -z -w1 "$ip" 22 2>/dev/null; then
                ssh_open="yes"
            fi
            
            if _timeout 2 nc -z -w1 "$ip" 445 2>/dev/null; then
                smb_open="yes"
            fi
            
            echo "${ip}|${hostname}|${mac}|${ssh_open}|${smb_open}"
        ) >> "$results_file" &
        pids+=($!)
    done < "$tmpfile"

    # Wait for all checks (max 10 seconds)
    local deadline=$((SECONDS + 10))
    for pid in "${pids[@]}"; do
        local remaining=$((deadline - SECONDS))
        if [ "$remaining" -gt 0 ]; then
            _timeout "$remaining" wait "$pid" 2>/dev/null
        else
            kill "$pid" 2>/dev/null
        fi
    done
    wait 2>/dev/null

    # Output results (SSH-capable hosts first, then SMB-capable hosts)
    # Field order: ip|hostname|mac|ssh_open|smb_open
    # Sort by SSH open (desc), then SMB open (desc)
    sort -t'|' -k4 -r -k5 -r "$results_file" 2>/dev/null

    rm -f "$tmpfile" "$results_file"
}

# ─── scan-tailscale ────────────────────────────────────────────────────────

# Discover peers visible via the local Tailscale tailnet. Unlike LAN scanning
# this is a single API call (`tailscale status --json`) that lists every peer
# regardless of current network — so a laptop on public WiFi can still see
# "home-desktop" at 100.x.y.z with the right credentials.
# Pipe-delimited output: name|tailscale_ip|online|os
# Silently produces no output if Tailscale is not installed or the daemon
# is unauthenticated — callers should treat no-output as "feature not
# available" not as an error.
_scan_tailscale() {
    # Check Tailscale
    if command -v tailscale >/dev/null 2>&1; then
        local ts_json
        ts_json="$(tailscale status --json 2>/dev/null)"
        if [ -n "$ts_json" ] && [ "$ts_json" != "null" ]; then
            python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    peers = data.get('Peer', {})
    for key, peer in peers.items():
        name = peer.get('HostName', peer.get('DNSName', ''))
        ips = peer.get('TailscaleIPs', [])
        ip = ips[0] if ips else ''
        os_val = peer.get('OS', '')
        online = 'yes' if peer.get('Online', False) else 'no'
        tags = ','.join(peer.get('Tags', []))
        print(f'{name}|{ip}|{os_val}|{online}|tailscale')
    # Also show self
    self_node = data.get('Self', {})
    if self_node:
        name = self_node.get('HostName', '')
        ips = self_node.get('TailscaleIPs', [])
        ip = ips[0] if ips else ''
        os_val = self_node.get('OS', '')
        print(f'{name}|{ip}|{os_val}|yes|tailscale-self')
except Exception:
    pass
" "$ts_json" 2>/dev/null
        fi
    fi

    # Check WireGuard
    if command -v wg >/dev/null 2>&1; then
        local wg_out
        wg_out="$(wg show 2>/dev/null)"
        if [ -n "$wg_out" ]; then
            echo "$wg_out" | awk '
                /^peer:/ { peer=$2 }
                /endpoint:/ { endpoint=$2; sub(/:[0-9]+$/, "", endpoint) }
                /allowed ips:/ {
                    ip=$3; sub(/\/[0-9]+/, "", ip)
                    print peer"|"ip"||yes|wireguard"
                }
            '
        fi
    fi

    # Check WiFiman/generic VPN (utun interfaces with VPN-range IPs)
    ifconfig 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^utun[0-9]+:'; then
            local iface_name
            iface_name="$(echo "$line" | awk -F: '{print $1}')"
            local vpn_ip
            vpn_ip="$(ifconfig "$iface_name" 2>/dev/null | awk '/inet / {print $2}' | head -1)"
            if [ -n "$vpn_ip" ]; then
                # Skip Tailscale IPs (100.x.x.x) if Tailscale already detected
                if command -v tailscale >/dev/null 2>&1 && echo "$vpn_ip" | grep -qE '^100\.'; then
                    continue
                fi
                local vtype="vpn"
                if echo "$vpn_ip" | grep -qE '^172\.'; then
                    vtype="wifiman"
                fi
                echo "${iface_name}|${vpn_ip}||yes|${vtype}"
            fi
        fi
    done
}

# ─── import-ssh-config ─────────────────────────────────────────────────────

# Parse ~/.ssh/config and emit one host per line in pipe-delimited form:
#   alias|hostname|user|identity_file
# so the Add Workstation dialog can offer "Import from SSH config" as a
# one-click flow. We only look at explicit Host entries (skip wildcards and
# Match blocks) — matching against those requires a full ssh parser and
# risks importing hosts the user didn't mean to expose. Identity_file is
# resolved relative to ~/.ssh/ when it doesn't start with /.
_import_ssh_config() {
    local ssh_config="${HOME}/.ssh/config"
    [ ! -f "$ssh_config" ] && return 0

    python3 -c "
import os, sys

config_path = sys.argv[1]
hosts = []
current = None

with open(config_path) as f:
    for line in f:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

        if stripped.lower().startswith('host '):
            # Save previous host
            if current and current.get('alias') != '*':
                hosts.append(current)
            patterns = stripped.split()[1:]
            # Skip wildcard-only entries
            if all(p == '*' for p in patterns):
                current = None
                continue
            # Use first non-wildcard pattern as alias
            alias = next((p for p in patterns if '*' not in p), patterns[0])
            current = {'alias': alias, 'hostname': '', 'user': '', 'port': '22', 'keyfile': ''}
        elif current is not None:
            parts = stripped.split(None, 1)
            if len(parts) == 2:
                key, val = parts[0].lower(), parts[1]
                if key == 'hostname':
                    current['hostname'] = val
                elif key == 'user':
                    current['user'] = val
                elif key == 'port':
                    current['port'] = val
                elif key == 'identityfile':
                    current['keyfile'] = val

    # Don't forget last host
    if current and current.get('alias') != '*':
        hosts.append(current)

for h in hosts:
    hostname = h['hostname'] or h['alias']
    print(f\"{h['alias']}|{hostname}|{h['user']}|{h['port']}|{h['keyfile']}\")
" "$ssh_config" 2>/dev/null
}

# ─── probe-host ────────────────────────────────────────────────────────────

# Gather everything AutoFuse wants to know about a single host in one shot
# so the Add Workstation dialog can pre-fill every field from just an IP.
# Phases:
#   0. Protocol probe — is port 22 (SSH) open? Port 445 (SMB)? Both? Emits
#      `protocol\tsshfs` or `protocol\tsmb` and `smb_available\tyes` so the
#      GUI can suggest the right default.
#   1. OS detection — try `uname -s` over SSH first; if that fails, try
#      PowerShell over SSH to detect Windows (Windows OpenSSH spawns cmd.exe
#      not bash, so `uname` exits with 'command not found' even on healthy
#      Windows hosts).
#   2. Disk enumeration — OS-specific: `Get-PSDrive` for Windows (sized and
#      formatted via PowerShell), `df -h` for Linux/macOS. Each row is
#      `disk\tletter|label|/path` so the dialog can list them in one table.
#   3. MAC address — uses `getmac /v /fo csv` on Windows (PowerShell's
#      Get-NetAdapter quoting got mangled over SSH; getmac is plain CSV).
#      Linux/macOS use `ip link` / `ifconfig`.
# Output is a mix of `key\tvalue` header rows and `disk\t...` rows; main.m
# parses them line-by-line.
_probe_host() {
    local ip="$1"
    local user="${2:-$(whoami)}"
    local key="${3:-$HOME/.ssh/id_ed25519}"

    # Expand ~ in key path
    key="${key/#\~/$HOME}"

    [ -z "$ip" ] && { echo "error:missing_ip"; return 1; }

    # Step 0: Detect protocol availability (SMB port 445 and SSH port 22)
    local smb_available="no"
    local ssh_available="no"
    
    if _timeout 2 nc -z -w1 "$ip" 445 2>/dev/null; then
        smb_available="yes"
    fi
    
    if _timeout 2 nc -z -w1 "$ip" 22 2>/dev/null; then
        ssh_available="yes"
    fi
    
    # Suggest protocol based on availability
    if [ "$smb_available" = "yes" ] && [ "$ssh_available" = "no" ]; then
        # Only SMB available
        echo "protocol	smb"
    elif [ "$ssh_available" = "yes" ] && [ "$smb_available" = "yes" ]; then
        # Both available — prefer SSH for now (can be overridden by user)
        echo "protocol	sshfs"
        echo "smb_available	yes"
    elif [ "$ssh_available" = "yes" ]; then
        # Only SSH available
        echo "protocol	sshfs"
    fi

    # Early-exit when both ports are closed. Without this we'd still try SSH
    # with a 5s ConnectTimeout × 2 attempts (uname + PowerShell fallback) on
    # an unreachable host, blocking the caller for 14 seconds. The port
    # probe above (2×2s via _timeout/nc) is authoritative enough — if
    # neither 22 nor 445 is listening, there's nothing to probe further.
    if [ "$ssh_available" = "no" ] && [ "$smb_available" = "no" ]; then
        echo "error:probe_failed:host_unreachable"
        return 1
    fi

    local ssh_cmd=(ssh -o ConnectTimeout=5
        -o "StrictHostKeyChecking=accept-new"
        -o "UserKnownHostsFile=$AF_KNOWN_HOSTS"
        -o BatchMode=yes)

    if [ -f "$key" ]; then
        ssh_cmd+=(-i "$key")
    fi

    local target="${user}@${ip}"

    # Step 1: Detect OS by trying uname (Linux/macOS) then PowerShell (Windows)
    # Note: don't use _timeout wrapper with SSH — it breaks argument passing.
    # SSH has its own ConnectTimeout which is sufficient.
    local os_name=""
    os_name="$("${ssh_cmd[@]}" "$target" "uname -s" 2>/dev/null | tr -d '\r\n')"

    if [ -z "$os_name" ]; then
        # uname failed — try PowerShell (Windows OpenSSH uses cmd.exe, not bash)
        local ps_test
        ps_test="$("${ssh_cmd[@]}" "$target" 'powershell -NoProfile -Command "echo Windows"' 2>/dev/null | tr -d '\r\n')"
        [ "$ps_test" = "Windows" ] && os_name="Windows"
    fi

    if [ -z "$os_name" ]; then
        echo "error:probe_failed:cannot_detect_os"
        return 1
    fi

    echo "os	$os_name"

    # Step 2: Hostname
    local hn
    hn="$("${ssh_cmd[@]}" "$target" "hostname" 2>/dev/null | tr -d '\r\n')"
    echo "hostname	$hn"

    # Step 3: MAC + Disks — platform-specific
    # Note: SSH has ConnectTimeout=5, so no extra _timeout wrapper needed
    case "$os_name" in
        Linux)
            local mac
            mac="$("${ssh_cmd[@]}" "$target" "ip link show 2>/dev/null | grep -A1 'state UP' | grep ether | awk '{print \$2}' | head -1" 2>/dev/null | tr -d '\r\n')"
            echo "mac	$mac"
            "${ssh_cmd[@]}" "$target" "df -h --output=target,size,used 2>/dev/null | grep -E '^/' | grep -v tmpfs" 2>/dev/null | tr -d '\r' | while IFS= read -r dline; do
                [ -z "$dline" ] && continue
                local tgt sz us
                tgt="$(echo "$dline" | awk '{print $1}')"
                sz="$(echo "$dline" | awk '{print $2}')"
                us="$(echo "$dline" | awk '{print $3}')"
                echo "disk	${tgt}||${us}|${sz}"
            done
            ;;
        Darwin)
            local mac
            mac="$("${ssh_cmd[@]}" "$target" "ifconfig en0 2>/dev/null | grep ether | awk '{print \$2}'" 2>/dev/null | tr -d '\r\n')"
            echo "mac	$mac"
            "${ssh_cmd[@]}" "$target" "df -h 2>/dev/null | grep '^/dev'" 2>/dev/null | tr -d '\r' | while IFS= read -r dline; do
                [ -z "$dline" ] && continue
                local tgt sz us
                tgt="$(echo "$dline" | awk '{print $NF}')"
                sz="$(echo "$dline" | awk '{print $2}')"
                us="$(echo "$dline" | awk '{print $3}')"
                echo "disk	${tgt}||${us}|${sz}"
            done
            ;;
        Windows|CYGWIN*|MINGW*|MSYS*)
            # Windows: use getmac for MAC (more reliable than PowerShell via SSH)
            local mac_line
            mac_line="$("${ssh_cmd[@]}" "$target" \
                'getmac /v /fo csv' 2>/dev/null | tr -d '\r' | grep -v 'disconnesso\|disconnected\|Disconnected' | grep -v '^"Nome\|^"Connection' | head -1)"
            local mac=""
            if [ -n "$mac_line" ]; then
                # CSV: "name","adapter","mac","transport" — extract 3rd field
                mac="$(echo "$mac_line" | python3 -c "import csv,sys; r=list(csv.reader(sys.stdin)); print(r[0][2] if r and len(r[0])>2 else '')" 2>/dev/null)"
            fi
            echo "mac	$mac"
            # Disks via PowerShell Format-Table (simpler output, no quote issues)
            "${ssh_cmd[@]}" "$target" \
                'powershell -NoProfile -Command "Get-PSDrive -PSProvider FileSystem | Format-Table Name,Used,Free -AutoSize"' \
                2>/dev/null | tr -d '\r' | while IFS= read -r dline; do
                [ -z "$dline" ] && continue
                # Skip header lines (Name, ----)
                echo "$dline" | grep -qE '^Name|^-' && continue
                local dname dused dfree
                dname="$(echo "$dline" | awk '{print $1}')"
                dused="$(echo "$dline" | awk '{print $2}')"
                dfree="$(echo "$dline" | awk '{print $3}')"
                [ -z "$dname" ] && continue
                # Convert bytes to GB
                local used_gb total_gb
                # Pass remote-host values via argv + int() — never interpolate
                # untrusted Get-PSDrive output into the Python source.
                used_gb="$(python3 -c 'import sys; print(round(int(sys.argv[1])/1073741824, 1))' "${dused:-0}" 2>/dev/null)"
                total_gb="$(python3 -c 'import sys; print(round((int(sys.argv[1])+int(sys.argv[2]))/1073741824, 1))' "${dused:-0}" "${dfree:-0}" 2>/dev/null)"
                echo "disk	${dname}||${used_gb}|${total_gb}"
            done
            ;;
        *)
            echo "mac	"
            echo "error:unknown_os:$os_name"
            ;;
    esac
}

# ─── detect-vpn ────────────────────────────────────────────────────────────

# Report the VPN / overlay interfaces currently active on this Mac so the
# menu bar can surface them and the Add Workstation dialog can offer their
# subnets as candidate `vpn_ip` ranges.
# Output: iface|ip|type|gateway, one line per VPN. Known types:
#   - `tailscale` — the Tailscale tunnel (100.64/10 range)
#   - `wireguard` — identified by `utun` interfaces with a .conf profile
#   - `openvpn` — `tun`/`utun` with an associated openvpn process
#   - `wifiman` — Unifi WifiMan (named `utun-ts` or similar, discovered via DNS)
# Empty output means no VPN active — treat as expected, not error.
_detect_vpn() {
    # Linux: simple, robust best-effort (tailscale + wireguard) using iproute2.
    # The macOS utun-scan below is Darwin-specific and skipped here.
    if [ "$AF_OS" != "Darwin" ]; then
        if command -v tailscale >/dev/null 2>&1; then
            local ts_ip
            ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
            [ -n "$ts_ip" ] && echo "tailscale0|${ts_ip}|tailscale|"
        fi
        if command -v wg >/dev/null 2>&1; then
            local wiface wg_ip
            for wiface in $(wg show interfaces 2>/dev/null); do
                wg_ip="$(ip -o -4 addr show dev "$wiface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
                [ -n "$wg_ip" ] && echo "${wiface}|${wg_ip}|wireguard|"
            done
        fi
        return 0
    fi

    # Check Tailscale
    if command -v tailscale >/dev/null 2>&1; then
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null)"
        if [ -n "$ts_ip" ]; then
            # Find the interface
            local ts_iface
            ts_iface="$(ifconfig 2>/dev/null | grep -B5 "$ts_ip" | head -1 | awk -F: '{print $1}')"
            [ -z "$ts_iface" ] && ts_iface="utun-ts"
            echo "${ts_iface}|${ts_ip}|tailscale|"
        fi
    fi

    # Check WireGuard
    if command -v wg >/dev/null 2>&1; then
        local wg_ifaces
        wg_ifaces="$(wg show interfaces 2>/dev/null)"
        for wiface in $wg_ifaces; do
            local wg_ip
            wg_ip="$(ifconfig "$wiface" 2>/dev/null | awk '/inet / {print $2}' | head -1)"
            [ -n "$wg_ip" ] && echo "${wiface}|${wg_ip}|wireguard|"
        done
    fi

    # Detect Unifi WifiMan SD-WAN — bundles WireGuard internally, so the
    # `wg` CLI check above misses it. We look for the app's running daemon
    # (wifiman-desktopd / WiFiman Desktop), which indicates the overlay is
    # active. If present, its utun interface gets labeled wifiman below.
    local wifiman_active=0
    if pgrep -if 'wifiman' >/dev/null 2>&1; then
        wifiman_active=1
    fi

    # Check utun/tun interfaces for other VPNs
    ifconfig 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^(utun|tun)[0-9]+:'; then
            local iface_name
            iface_name="$(echo "$line" | awk -F: '{print $1}')"
            local vpn_ip
            vpn_ip="$(ifconfig "$iface_name" 2>/dev/null | awk '/inet / {print $2}' | head -1)"
            [ -z "$vpn_ip" ] && continue

            # Determine type
            local vtype="vpn"
            if echo "$vpn_ip" | grep -qE '^100\.'; then
                # Likely Tailscale — skip if already reported
                command -v tailscale >/dev/null 2>&1 && continue
                vtype="tailscale"
            elif echo "$vpn_ip" | grep -qE '^172\.'; then
                vtype="wifiman"
            elif [ "$wifiman_active" = "1" ]; then
                # WifiMan is running and we've excluded tailscale + explicit
                # 172.x range. Any remaining utun is most likely the WifiMan
                # SD-WAN tunnel (often 192.168.3.x in default configs).
                vtype="wifiman"
            fi

            # Get gateway if available
            local gw
            gw="$(route -n get "$vpn_ip" 2>/dev/null | awk '/gateway:/ {print $2}')"
            echo "${iface_name}|${vpn_ip}|${vtype}|${gw}"
        fi
    done
}

# ─── copy-key ─────────────────────────────────────────────────────────────

# Generate (but do NOT execute) the one-shot command that installs this
# Mac's public SSH key on the remote host. Returns two lines:
#   cmd:<shell command the user runs once, interactively, on this Mac>
#   os:<linux|darwin|windows|...>
# Windows is the hard case — OpenSSH's default config requires admin-shared
# keys to live in C:\ProgramData\ssh\administrators_authorized_keys with
# strict ACLs, while non-admin users use ~/.ssh/authorized_keys. We detect
# which via a PowerShell script embedded in the cmd, so the single command
# works for both kinds of account. For Unix, we prefer `ssh-copy-id` and
# fall back to appending the pubkey manually. We return the command string
# instead of running it because the user still needs to type their remote
# password once — AutoFuse itself has no password input and must not prompt.
_copy_key() {
    local ip="$1"
    local user="${2:-$(whoami)}"
    local keyfile="${3:-$HOME/.ssh/id_ed25519}"

    # Expand ~ in key path
    keyfile="${keyfile/#\~/$HOME}"

    [ -z "$ip" ] && { echo "error:missing_ip"; return 1; }

    local pubkey="${keyfile}.pub"
    if [ ! -f "$pubkey" ]; then
        echo "error:pubkey_not_found:${pubkey}"
        return 1
    fi

    # Detect remote OS via SSH (using BatchMode if key is already deployed,
    # otherwise this will fail and we fall back to interactive terminal)
    local ssh_cmd=(ssh -o ConnectTimeout=5
        -o "StrictHostKeyChecking=accept-new"
        -o "UserKnownHostsFile=$AF_KNOWN_HOSTS"
        -o BatchMode=yes)

    if [ -f "$keyfile" ]; then
        ssh_cmd+=(-i "$keyfile")
    fi

    local target="${user}@${ip}"
    local os_name=""
    os_name="$("${ssh_cmd[@]}" "$target" "uname -s" 2>/dev/null | tr -d '\r\n')"

    if [ -z "$os_name" ]; then
        local ps_test
        ps_test="$("${ssh_cmd[@]}" "$target" 'powershell -NoProfile -Command "echo Windows"' 2>/dev/null | tr -d '\r\n')"
        [ "$ps_test" = "Windows" ] && os_name="Windows"
    fi

    # Generate the appropriate command to copy the SSH key
    case "$os_name" in
        Windows|CYGWIN*|MINGW*|MSYS*)
            # For Windows, check if user is admin and use appropriate path
            # Generate a PowerShell command that handles both admin and non-admin
            local pub_content
            pub_content="$(cat "$pubkey")"
            # Escape single quotes for PowerShell
            pub_content="$(echo "$pub_content" | sed "s/'/''/g")"
            local ps_cmd="\$key = '${pub_content}'; "
            ps_cmd+="\$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); "
            ps_cmd+="if (\$isAdmin) { "
            ps_cmd+="\$authKeysPath = 'C:\\ProgramData\\ssh\\administrators_authorized_keys'; "
            ps_cmd+="if (!(Test-Path \$authKeysPath)) { New-Item -ItemType File -Path \$authKeysPath -Force | Out-Null }; "
            ps_cmd+="\$existing = Get-Content \$authKeysPath -ErrorAction SilentlyContinue; "
            ps_cmd+="if (\$existing -notcontains \$key) { Add-Content -Path \$authKeysPath -Value \$key }; "
            ps_cmd+="icacls \$authKeysPath /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null; "
            ps_cmd+="Write-Host 'ok:key_copied:admin' "
            ps_cmd+="} else { "
            ps_cmd+="\$sshDir = \"\$env:USERPROFILE\\.ssh\"; "
            ps_cmd+="if (!(Test-Path \$sshDir)) { New-Item -ItemType Directory -Path \$sshDir -Force | Out-Null }; "
            ps_cmd+="\$authKeysPath = \"\$sshDir\\authorized_keys\"; "
            ps_cmd+="\$existing = Get-Content \$authKeysPath -ErrorAction SilentlyContinue; "
            ps_cmd+="if (\$existing -notcontains \$key) { Add-Content -Path \$authKeysPath -Value \$key }; "
            ps_cmd+="Write-Host 'ok:key_copied:user' "
            ps_cmd+="}"

            # Output as a terminal command the user can run interactively
            echo "cmd:ssh ${user}@${ip} \"powershell -NoProfile -Command \\\"${ps_cmd}\\\"\""
            echo "os:windows"
            ;;
        Linux|Darwin|*)
            # For Linux/macOS, use ssh-copy-id (interactive — needs password)
            if command -v ssh-copy-id >/dev/null 2>&1; then
                echo "cmd:ssh-copy-id -i '${pubkey}' '${user}@${ip}'"
                echo "os:${os_name:-unix}"
            else
                # Fallback: manual append
                local pub_content
                pub_content="$(cat "$pubkey")"
                echo "cmd:ssh '${user}@${ip}' 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \"${pub_content}\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
                echo "os:${os_name:-unix}"
            fi
            ;;
    esac
}

# ─── Command dispatch ─────────────────────────────────────────────────────

case "$1" in
scan-network)
    _scan_network
    ;;
scan-tailscale)
    _scan_tailscale
    ;;
import-ssh-config)
    _import_ssh_config
    ;;
probe-host)
    [ -z "$2" ] && { echo "error:missing_ip"; exit 1; }
    _probe_host "$2" "$3" "$4"
    ;;
detect-vpn)
    _detect_vpn
    ;;
copy-key)
    [ -z "$2" ] && { echo "error:missing_ip"; exit 1; }
    _copy_key "$2" "$3" "$4"
    ;;
*)
    echo "AutoFuse Discovery"
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  scan-network              Scan local network for SSH hosts"
    echo "  scan-tailscale            List Tailscale/WireGuard/WiFiman peers"
    echo "  import-ssh-config         Parse ~/.ssh/config for hosts"
    echo "  probe-host <ip> [user] [key]  Probe host for MAC, disks, OS"
    echo "  detect-vpn                Detect active VPN interfaces"
    echo "  copy-key <ip> [user] [key]    Generate command to copy SSH key to remote host"
    exit 1
    ;;
esac
