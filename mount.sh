#!/bin/bash
# AutoFuse v4 — robust multi-workstation SSHFS with WoL + auto-recovery
# Usage: mount.sh <command> [workstation] [disk]
# Commands: list, disks, status, status-all, mount, mount-all, unmount, unmount-all,
#           wol, heal, heal-all, ping-check, check-deps, keychain-add,
#           health, health-json, export-config, import-config, log, log-clear
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ─── OS portability layer ───────────────────────────────────────────────────
# AutoFuse runs on macOS (FUSE-T/macFUSE) and Linux (libfuse + sshfs). The
# engine is the single source of truth for both; only a handful of commands
# differ between the platforms and are branched on AF_OS here.
AF_OS="$(uname -s)"

# ping with a real 2s deadline. macOS: -t = timeout seconds. Linux: -t = TTL,
# so the timeout flag is -W (seconds). Echoes ping output, returns ping's exit.
_ping_host() {
    local ip="$1"
    if [ "$AF_OS" = "Darwin" ]; then
        ping -c1 -t2 "$ip" 2>/dev/null
    else
        ping -c1 -W2 "$ip" 2>/dev/null
    fi
}

# Force-unmount a FUSE mount point. macOS uses diskutil; Linux uses fusermount.
_force_unmount() {
    local mp="$1"
    if [ "$AF_OS" = "Darwin" ]; then
        diskutil unmount force "$mp" 2>/dev/null
    else
        fusermount3 -u "$mp" 2>/dev/null || fusermount -u "$mp" 2>/dev/null
    fi
}

# Same, but time-bounded (3s) so a dead mount can't hang the sweep. macOS has no
# `timeout`, so it uses the perl-alarm trick; Linux uses coreutils `timeout`.
_force_unmount_t() {
    local mp="$1"
    if [ "$AF_OS" = "Darwin" ]; then
        perl -e 'alarm 3; exec @ARGV' diskutil unmount force "$mp" 2>/dev/null
    else
        timeout 3 fusermount3 -u "$mp" 2>/dev/null || timeout 3 fusermount -u "$mp" 2>/dev/null
    fi
}

# List the mount points of every sshfs/FUSE mount, one per line. The `mount`
# output format differs: macOS is "src on /path (type,…)", Linux is
# "src on /path type fuse.sshfs (…)".
_list_fuse_mounts() {
    if [ "$AF_OS" = "Darwin" ]; then
        mount | grep -E 'osxfuse|macfuse|fuse-t' | sed -n 's/^.* on \(.*\) (.*$/\1/p'
    else
        mount -t fuse.sshfs 2>/dev/null | sed -n 's/^.* on \(.*\) type .*$/\1/p'
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# User config is ALWAYS preferred (it's the source of truth).
# Bundle config is only a fallback template for first-run before user config exists.
CONFIG="$HOME/.config/autofuse/config.json"
[ ! -f "$CONFIG" ] && CONFIG="$SCRIPT_DIR/config.json"
[ ! -f "$CONFIG" ] && CONFIG="$SCRIPT_DIR/../Resources/config.json"
if [ ! -f "$CONFIG" ] && [ -f "$HOME/.config/workstationmount/config.json" ]; then
    # One-time migration: copy old config to new location
    mkdir -p "$HOME/.config/autofuse" 2>/dev/null
    cp "$HOME/.config/workstationmount/config.json" "$HOME/.config/autofuse/config.json"
    chmod 600 "$HOME/.config/autofuse/config.json" 2>/dev/null
    CONFIG="$HOME/.config/autofuse/config.json"
fi
[ ! -f "$CONFIG" ] && { echo "error:no_config"; exit 1; }

# Validate JSON config on load (pass path via argv — never interpolate into Python source)
if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$CONFIG" 2>/dev/null; then
    echo "error:invalid_json"
    exit 1
fi

# ─── Logging ───────────────────────────────────────────────────────────────
AF_LOG="$HOME/.config/autofuse/autofuse.log"
mkdir -p "$(dirname "$AF_LOG")" 2>/dev/null

_log_rotate() {
    # Rotate log if >1MB (keep only 1 backup)
    if [ -f "$AF_LOG" ]; then
        local size
        size=$(stat -f%z "$AF_LOG" 2>/dev/null || stat -c%s "$AF_LOG" 2>/dev/null || echo 0)
        if [ "$size" -gt 1048576 ] 2>/dev/null; then
            mv -f "$AF_LOG" "${AF_LOG}.old"
        fi
    fi
}

_log() {
    _log_rotate
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$AF_LOG"
}

# Dedicated known_hosts for AutoFuse
AF_KNOWN_HOSTS="$HOME/.config/autofuse/known_hosts"
mkdir -p "$(dirname "$AF_KNOWN_HOSTS")" 2>/dev/null
# Migrate old known_hosts if new one doesn't exist yet
if [ ! -f "$AF_KNOWN_HOSTS" ] && [ -f "$HOME/.config/workstationmount/known_hosts" ]; then
    cp "$HOME/.config/workstationmount/known_hosts" "$AF_KNOWN_HOSTS"
fi

# Smart endpoint memory: remember which endpoint was last-working per
# workstation so `_pick_endpoint` can try it first instead of iterating
# lan→vpn→extras→mDNS every mount. TTL=1h keeps the cache useful across
# repeated mounts on the same network (studio, home, cellular) without
# pinning us to a stale endpoint after a network switch.
AF_ENDPOINT_CACHE_DIR="$HOME/.config/autofuse/.endpoint-cache"
_ENDPOINT_CACHE_TTL_SEC=3600

# ─── JSON helper (safe — no eval) ───────────────────────────────────────────

_json_raw() {
    # Returns raw JSON output; callers parse specific fields with read/IFS
    python3 -c "
import json, sys, os

config_path = sys.argv[1]
query = sys.argv[2] if len(sys.argv) > 2 else ''
ws_name = sys.argv[3] if len(sys.argv) > 3 else ''
disk = sys.argv[4] if len(sys.argv) > 4 else ''

with open(config_path) as f:
    cfg = json.load(f)

if query == 'list_workstations':
    for w in cfg.get('workstations', []):
        disks = ','.join(d['letter'] for d in w.get('disks', []))
        mac = w.get('mac_address', '')
        print(f\"{w['name']}|{w.get('lan_ip','')}|{w.get('vpn_ip','')}|{disks}|{mac}\")
elif query == 'mount_base':
    print(os.path.expanduser(cfg.get('mount_base', '~/workstation')))
elif query == 'workstation':
    for w in cfg.get('workstations', []):
        if w['name'] == ws_name:
            key = os.path.expanduser(w.get('ssh_key', '~/.ssh/id_ed25519'))
            # Output as tab-separated key-value pairs (safe for read)
            print('user\t' + w.get('user', ''))
            print('lan_ip\t' + w.get('lan_ip', ''))
            print('vpn_ip\t' + w.get('vpn_ip', ''))
            print('mac_address\t' + w.get('mac_address', ''))
            print('ssh_key\t' + key)
            print('protocol\t' + w.get('protocol', 'sshfs'))
            print('smb_share\t' + w.get('smb_share', ''))
            print('host_key_sha256\t' + w.get('host_key_sha256', ''))
            for extra in w.get('additional_ips', []):
                print('additional_ip\t' + str(extra))
            break
elif query == 'disk':
    for w in cfg.get('workstations', []):
        if w['name'] == ws_name:
            for d in w.get('disks', []):
                if d['letter'] == disk:
                    print('remote_path\t' + d.get('remote_path', ''))
                    print('label\t' + d.get('label', ''))
                    break
            break
elif query == 'disks':
    for w in cfg.get('workstations', []):
        if w['name'] == ws_name:
            for d in w.get('disks', []):
                print(f\"{d['letter']}|{d.get('label','')}|{d['remote_path']}\")
            break
elif query == 'is_primary':
    for w in cfg.get('workstations', []):
        if w['name'] == ws_name:
            for d in w.get('disks', []):
                if d['letter'] == disk:
                    print('yes' if d.get('primary', False) else 'no')
                    break
            break
elif query == 'ssh_opts':
    s = cfg.get('ssh_options', {})
    c = cfg.get('cache_options', {})
    io = cfg.get('io_options', {})
    parts = []
    cipher = s.get('cipher')
    if cipher:
        parts.append('-o')
        parts.append(f'Ciphers={cipher}')
    if not s.get('compression', True):
        parts.append('-o')
        parts.append('Compression=no')
    parts.append('-o')
    parts.append(f\"ServerAliveInterval={s.get('keepalive_interval',30)}\")
    parts.append('-o')
    parts.append(f\"ServerAliveCountMax={s.get('keepalive_count',3)}\")
    # ConnectTimeout bounds the initial TCP/SSH handshake. Default 30s is
    # generous enough for ~1s RTT links (handshake ≈ 4-8 roundtrips) while
    # still failing fast on dead hosts. Config key: ssh_options.connect_timeout.
    parts.append('-o')
    parts.append(f\"ConnectTimeout={s.get('connect_timeout',30)}\")
    if c.get('kernel_cache'):
        parts.append('-o')
        parts.append('kernel_cache')
    if c.get('auto_cache'):
        parts.append('-o')
        parts.append('auto_cache')
    parts.append('-o')
    parts.append('cache=yes')
    for k in ['cache_timeout','attr_timeout','entry_timeout','negative_timeout']:
        v = c.get(k, c.get('cache_timeout', 115200))
        parts.append('-o')
        parts.append(f'{k}={v}')
    iosize = io.get('iosize')
    if iosize:
        parts.append('-o')
        parts.append(f'iosize={iosize}')
    parts.append('-o')
    parts.append('big_writes')
    max_write = io.get('max_write')
    if max_write:
        parts.append('-o')
        parts.append(f'max_write={max_write}')
    if io.get('noappledouble'):
        parts.append('-o')
        parts.append('noappledouble')
    if io.get('noapplexattr'):
        parts.append('-o')
        parts.append('noapplexattr')
    if io.get('defer_permissions'):
        parts.append('-o')
        parts.append('defer_permissions')
    parts.extend(['-o', 'follow_symlinks', '-o', 'reconnect'])
    # Output one arg per line for safe reading via mapfile
    for p in parts:
        print(p)
" "$CONFIG" "$@"
}

# Safe field reader: reads tab-separated key-value pairs into local variables
# Usage: _read_workstation "ws_name"
# Sets: ws_user, ws_lan_ip, ws_vpn_ip, ws_mac_address, ws_ssh_key, ws_protocol, ws_smb_share
_read_workstation() {
    local _ws_name="$1"
    ws_user="" ws_lan_ip="" ws_vpn_ip="" ws_mac_address="" ws_ssh_key="" ws_protocol="sshfs" ws_smb_share=""
    ws_host_key_sha256=""
    ws_additional_ips=()
    while IFS=$'\t' read -r _key _val; do
        case "$_key" in
            user) ws_user="$_val" ;;
            lan_ip) ws_lan_ip="$_val" ;;
            vpn_ip) ws_vpn_ip="$_val" ;;
            mac_address) ws_mac_address="$_val" ;;
            ssh_key) ws_ssh_key="$_val" ;;
            protocol) ws_protocol="$_val" ;;
            smb_share) ws_smb_share="$_val" ;;
            host_key_sha256) ws_host_key_sha256="$_val" ;;
            additional_ip) [ -n "$_val" ] && ws_additional_ips+=("$_val") ;;
        esac
    done < <(_json_raw workstation "$_ws_name")
}

# Compute SHA256 fingerprint of remote host's SSH host key (ed25519 preferred)
# Usage: _get_remote_host_key_sha256 <host> [port]
# Returns: "SHA256:..." on success, empty string on failure
_get_remote_host_key_sha256() {
    local _host="$1" _port="${2:-22}"
    [ -z "$_host" ] && return 1
    ssh-keyscan -T 3 -p "$_port" -t ed25519 "$_host" 2>/dev/null | \
        grep -v '^#' | \
        ssh-keygen -l -E sha256 -f - 2>/dev/null | \
        awk '{print $2}' | \
        head -1
}

# TOFU auto-learn: after a successful mount, capture the server's host key
# fingerprint into config.json if none is stored yet. Subsequent mounts then
# benefit from `_pick_endpoint` verification automatically — users never have
# to run `learn-host-key` manually. Silent on failure (this is best-effort;
# the mount already succeeded, we must not let fingerprint capture fail the
# overall operation).
_maybe_learn_host_key() {
    local _ws_name="$1" _host="$2"
    [ -z "$_ws_name" ] || [ -z "$_host" ] && return 0
    # Skip if already stored (we don't want to silently overwrite a key that
    # might differ — that's a legitimate trust event the user should resolve).
    _read_workstation "$_ws_name"
    [ -n "$ws_host_key_sha256" ] && return 0
    local _sha
    _sha="$(_get_remote_host_key_sha256 "$_host")"
    [ -z "$_sha" ] && return 0
    python3 - "$CONFIG" "$_ws_name" "$_sha" 2>/dev/null <<'PY' || return 0
import json, sys, os, tempfile, re
cfg_path, ws_name, sha = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg_path) as f:
    cfg = json.load(f)
for w in cfg.get('workstations', []):
    if w['name'] == ws_name and not w.get('host_key_sha256'):
        w['host_key_sha256'] = sha
        break
else:
    sys.exit(0)
# Match Apple's NSJSONWritingPrettyPrinted style so diffs stay tiny when the
# app re-saves later: `"key" : value` (space before colon) instead of
# Python's default `"key": value`. JSON values never start with a `"..." :`
# pattern at line-start, so this regex is safe.
_text = re.sub(r'^(\s*"[^"]+"):', r'\1 :', json.dumps(cfg, indent=2), flags=re.MULTILINE)
_dir = os.path.dirname(os.path.abspath(cfg_path)) or '.'
_tmp = tempfile.NamedTemporaryFile('w', delete=False, dir=_dir, prefix='.autofuse-tofu-')
_tmp.write(_text + '\n')
_tmp.flush(); os.fsync(_tmp.fileno()); _tmp.close()
os.chmod(_tmp.name, 0o600)
os.replace(_tmp.name, cfg_path)
PY
    _log "tofu: auto-learned host key for $_ws_name via $_host → $_sha"
}

# Exclude a mount point from Spotlight indexing and Time Machine backup.
# Runs once per mount — both tools are idempotent so repeated calls are safe,
# but we silence their output to avoid log noise. Addresses two real UX
# issues: (a) Spotlight indexing a multi-TB remote disk floods the SSH
# tunnel and burns CPU; (b) Time Machine backup traverses the mount and
# hangs hourly backups. Both were previously "manual workarounds" in the
# troubleshooting doc — now automatic on every successful mount.
_exclude_from_indexing() {
    local _mp="$1"
    [ -z "$_mp" ] || [ ! -d "$_mp" ] && return 0
    # Spotlight: disable indexing for this volume. mdutil writes to the
    # .Spotlight-V100 metadata dir; on FUSE mounts this typically no-ops
    # but prevents mds from even trying.
    mdutil -i off "$_mp" >/dev/null 2>&1 || true
    # Time Machine: add to exclusions list. tmutil requires the path to
    # exist; our caller only invokes after a confirmed mount so this is safe.
    tmutil addexclusion "$_mp" >/dev/null 2>&1 || true
}

# Endpoint-cache helpers: persist the last-working endpoint per workstation
# so repeated mounts on the same network skip the full lan→vpn→extras→mDNS
# probe chain. Each file stores one line: `<endpoint>\t<rtt_ms>\t<timestamp>`.
# RTT is a placeholder today (0) — the field exists so future versions can
# rank endpoints by latency without changing the file format.
_endpoint_cache_file() {
    local _ws="$1"
    # Sanitize the ws name so adversarial characters (/, ..) cannot escape
    # the cache dir. Same filter as known_hosts naming would use.
    local _safe
    _safe="$(printf '%s' "$_ws" | LC_ALL=C tr -c 'A-Za-z0-9._-' _)"
    echo "${AF_ENDPOINT_CACHE_DIR}/${_safe}"
}

# Read cached endpoint for a workstation. Echoes the endpoint if the cache
# file exists, is well-formed, and is within TTL. Returns non-zero (no
# output) otherwise. Silent on missing/corrupted cache — always safe to
# fall back to the full endpoint iteration.
_endpoint_cache_get() {
    local _ws="$1"
    local _f
    _f="$(_endpoint_cache_file "$_ws")"
    [ -f "$_f" ] || return 1
    local _line _ep _rtt _ts _now _age
    _line="$(cat "$_f" 2>/dev/null)" || return 1
    IFS=$'\t' read -r _ep _rtt _ts <<< "$_line"
    [ -z "$_ep" ] && return 1
    # Defend against corrupted cache: non-numeric timestamp would blow up
    # the arithmetic below with a bash syntax error. Treat as miss.
    [[ "$_ts" =~ ^[0-9]+$ ]] || return 1
    _now="$(date +%s)"
    _age=$((_now - _ts))
    [ "$_age" -gt "$_ENDPOINT_CACHE_TTL_SEC" ] && return 1
    echo "$_ep"
    return 0
}

# Emit an endpoint-switch event file consumable by the menu-bar app.
# Drops a file at ~/.config/autofuse/.events/switch-<ts>-<pid> holding
# `<ws>\t<old>\t<new>\t<ts>`. main.m's pollStatus timer scans the dir,
# posts a native UNUserNotification per entry, then deletes the file —
# so stale events self-clean. Silent on failure and no-op when old==new
# (protects against spurious events when the cache iteration picks the
# same endpoint a second time).
_emit_switch_event() {
    local _ws="$1" _old="$2" _new="$3"
    [ -z "$_ws" ] || [ -z "$_new" ] && return 0
    [ "$_old" = "$_new" ] && return 0
    local _dir="$HOME/.config/autofuse/.events"
    mkdir -p "$_dir" 2>/dev/null
    local _ts _file
    _ts="$(date +%s)"
    _file="${_dir}/switch-${_ts}-$$"
    printf '%s\t%s\t%s\t%s' "$_ws" "$_old" "$_new" "$_ts" > "$_file" 2>/dev/null
    _log "event:endpoint_switch ${_ws} ${_old:-none}->${_new}"
}

# Atomically write the last-working endpoint for a workstation. Same
# tmpfile+rename pattern used for config.json so a crash mid-write cannot
# corrupt the cache file. RTT defaults to 0 when unknown.
_endpoint_cache_set() {
    local _ws="$1" _ep="$2" _rtt="${3:-0}"
    [ -z "$_ws" ] || [ -z "$_ep" ] && return 0
    mkdir -p "$AF_ENDPOINT_CACHE_DIR" 2>/dev/null
    local _f _ts _tmp
    _f="$(_endpoint_cache_file "$_ws")"
    _ts="$(date +%s)"
    _tmp="${_f}.tmp.$$"
    if printf '%s\t%s\t%s' "$_ep" "$_rtt" "$_ts" > "$_tmp" 2>/dev/null; then
        mv -f "$_tmp" "$_f" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    fi
}

# List all candidate endpoints for a workstation in priority order.
# Emits one host per line: lan_ip, vpn_ip, additional_ips, then <name>.local (mDNS).
# Usage: _list_endpoints <ws_name>
_list_endpoints() {
    local _ws_name="$1"
    _read_workstation "$_ws_name"
    [ -n "$ws_lan_ip" ] && echo "$ws_lan_ip"
    [ -n "$ws_vpn_ip" ] && echo "$ws_vpn_ip"
    local _extra
    for _extra in "${ws_additional_ips[@]}"; do
        [ -n "$_extra" ] && echo "$_extra"
    done
    echo "${_ws_name}.local"
}

# Pick first reachable endpoint whose host key matches ws_host_key_sha256.
# If ws_host_key_sha256 is empty, returns first reachable (learn mode).
# Usage: _pick_endpoint <ws_name>
# Echoes the chosen host to stdout; empty string if none found.
#
# Smart-endpoint fast path: before iterating the full candidate list, try
# the last-working endpoint from the per-ws cache. On a repeated mount from
# the same network this avoids up to 4 × 2s `_reachable` probes plus the
# ssh-keyscan on the wrong endpoints. Cache-miss, stale cache, unreachable
# cached endpoint, or key-mismatch all fall through cleanly to the full
# iteration — so cache can only help, never hurt.
_pick_endpoint() {
    local _ws_name="$1"
    _read_workstation "$_ws_name"
    local _expected="$ws_host_key_sha256"
    local _candidate _current_sha

    local _cached _rtt
    _cached="$(_endpoint_cache_get "$_ws_name" 2>/dev/null)"
    if [ -n "$_cached" ] && _reachable "$_cached" 2>/dev/null; then
        if [ -n "$_expected" ]; then
            _current_sha="$(_get_remote_host_key_sha256 "$_cached")"
            if [ "$_current_sha" = "$_expected" ]; then
                _rtt="$(_ping_rtt "$_cached")"
                _endpoint_cache_set "$_ws_name" "$_cached" "${_rtt:-0}"
                echo "$_cached"; return 0
            fi
            # Cache hit reached, key mismatch — don't trust it, fall
            # through. The iteration below will pick (and re-cache) a
            # verified endpoint.
        else
            _rtt="$(_ping_rtt "$_cached")"
            _endpoint_cache_set "$_ws_name" "$_cached" "${_rtt:-0}"
            echo "$_cached"; return 0
        fi
    fi

    while IFS= read -r _candidate; do
        [ -z "$_candidate" ] && continue
        _reachable "$_candidate" 2>/dev/null || continue
        if [ -n "$_expected" ]; then
            _current_sha="$(_get_remote_host_key_sha256 "$_candidate")"
            if [ "$_current_sha" = "$_expected" ]; then
                _emit_switch_event "$_ws_name" "$_cached" "$_candidate"
                _rtt="$(_ping_rtt "$_candidate")"
                _endpoint_cache_set "$_ws_name" "$_candidate" "${_rtt:-0}"
                echo "$_candidate"; return 0
            fi
            _log "pick_endpoint: $_candidate key mismatch (expected $_expected, got $_current_sha)"
            continue
        fi
        _emit_switch_event "$_ws_name" "$_cached" "$_candidate"
        _rtt="$(_ping_rtt "$_candidate")"
        _endpoint_cache_set "$_ws_name" "$_candidate" "${_rtt:-0}"
        echo "$_candidate"; return 0
    done < <(_list_endpoints "$_ws_name")
    return 1
}

# Usage: _read_disk "ws_name" "disk_letter"
# Sets: disk_remote_path, disk_label
_read_disk() {
    local _ws_name="$1" _disk_letter="$2"
    disk_remote_path="" disk_label=""
    while IFS=$'\t' read -r _key _val; do
        case "$_key" in
            remote_path) disk_remote_path="$_val" ;;
            label) disk_label="$_val" ;;
        esac
    done < <(_json_raw disk "$_ws_name" "$_disk_letter")
}

# Read ssh_opts into global array safely (one arg per line)
# Sets: SSH_OPTS array
_read_ssh_opts() {
    SSH_OPTS=()
    while IFS= read -r line; do
        SSH_OPTS+=("$line")
    done < <(_json_raw ssh_opts)
}

# ─── Mount point resolution (safe — no inline python interpolation) ─────────

# Decide where a given disk should be mounted on the local filesystem.
# The rules balance a clean single-workstation UX with correctness when
# multiple workstations or multiple disks per workstation are configured:
#   1. If a disk is marked `primary`, it takes the base path (`~/workstation`
#      when there's only one workstation, or `~/workstation/<ws>` otherwise).
#   2. Non-primary disks always mount as *siblings* of the primary, never
#      nested inside it — FUSE cannot mount inside another FUSE mount on
#      macOS, and even when it could, nesting freezes Finder if the outer
#      mount stales. Siblings use `~/workstation-<letter>` in the single-ws
#      case, `~/workstation/<ws>-<letter>` in the multi-ws case.
#   3. Workstations with no primary disk fall back to `~/workstation/<letter>`
#      (or `~/workstation/<ws>/<letter>` for multi-ws), keeping each letter
#      isolated.
# Any change here must round-trip through the existing 39 tests — path layout
# is load-bearing for `status`, `heal`, and the panic-unmount cleanup.
_mount_point() {
    local base ws_name disk_letter
    base="$(_json_raw mount_base)"
    ws_name="$1"
    disk_letter="$2"

    local is_primary
    is_primary="$(_json_raw is_primary "$ws_name" "$disk_letter")"

    local ws_count
    ws_count=$(_json_raw list_workstations | wc -l | tr -d ' ')

    if [ "$is_primary" = "yes" ]; then
        # Primary disk mounts at base (backward compat)
        [ "$ws_count" -eq 1 ] && echo "$base" || echo "${base}/${ws_name}"
    else
        # Non-primary disks: check if workstation has a primary disk
        # If so, mount OUTSIDE the primary mount point to avoid nesting
        local has_primary=""
        has_primary=$(_json_raw list_workstations | while IFS='|' read -r n l v d m; do
            [ "$n" = "$ws_name" ] || continue
            IFS=',' read -ra darr <<< "$d"
            for dl in "${darr[@]}"; do
                local chk
                chk="$(_json_raw is_primary "$ws_name" "$dl")"
                [ "$chk" = "yes" ] && echo "yes" && break
            done
        done)

        if [ "$has_primary" = "yes" ]; then
            # Sibling of primary: mount at base-LETTER (e.g., ~/workstation-C)
            if [ "$ws_count" -eq 1 ]; then
                echo "${base}-${disk_letter}"
            else
                echo "${base}/${ws_name}-${disk_letter}"
            fi
        elif [ "$ws_count" -eq 1 ]; then
            echo "${base}/${disk_letter}"
        else
            echo "${base}/${ws_name}/${disk_letter}"
        fi
    fi
}

# ─── FUSE backend detection ───────────────────────────────────────────────

_detect_fuse_backend() {
    # Linux: libfuse ships with the distro; the sshfs binary is the real
    # dependency (it pulls in fuse2/fuse3). If it's on PATH, we're good.
    if [ "$AF_OS" != "Darwin" ]; then
        if command -v sshfs >/dev/null 2>&1; then
            echo "linuxfuse"
            return 0
        fi
        echo "none"
        return 1
    fi

    # Check for macFUSE (kernel extension)
    if [ -d "/Library/Filesystems/macfuse.fs" ] || kextstat 2>/dev/null | grep -q macfuse; then
        echo "macfuse"
        return 0
    fi

    # Check for FUSE-T (userspace NFS transport, no kext)
    if [ -f "/usr/local/lib/libfuse-t.dylib" ] || brew list fuse-t >/dev/null 2>&1; then
        echo "fuset"
        return 0
    fi

    echo "none"
    return 1
}

_find_sshfs_binary() {
    local backend="$1"
    case "$backend" in
        macfuse)
            # macFUSE sshfs is typically installed via Homebrew
            for p in /opt/homebrew/bin/sshfs /usr/local/bin/sshfs; do
                [ -x "$p" ] && echo "$p" && return 0
            done
            ;;
        fuset)
            # FUSE-T sshfs (fuse-t-sshfs) installs to /usr/local/bin
            for p in /usr/local/bin/sshfs /opt/homebrew/bin/sshfs; do
                [ -x "$p" ] && echo "$p" && return 0
            done
            ;;
    esac
    # Fallback: check PATH
    command -v sshfs 2>/dev/null && return 0
    return 1
}

# ─── Dependency check ──────────────────────────────────────────────────────

_check_sshfs() {
    local backend
    backend="$(_detect_fuse_backend)"

    if [ "$backend" = "none" ]; then
        echo "error:no_fuse_backend"
        return 1
    fi

    local sshfs_path
    sshfs_path="$(_find_sshfs_binary "$backend")"
    if [ -z "$sshfs_path" ]; then
        echo "error:sshfs_not_found"
        return 1
    fi

    # python3 is an undeclared hard dependency (~20 inline JSON/arithmetic
    # helpers rely on it); surface its absence here instead of failing later
    # with a misleading "invalid_json".
    command -v python3 >/dev/null 2>&1 || echo "warn:python3_not_found"

    echo "ok:sshfs:${backend}"
    return 0
}

# ─── Keychain / SSH agent helpers ─────────────────────────────────────────

_ensure_ssh_agent() {
    # Start ssh-agent if not running
    if [ -z "$SSH_AUTH_SOCK" ] || ! ssh-add -l >/dev/null 2>&1; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1
        _log "ssh-agent started (PID=$SSH_AGENT_PID)"
    fi
}

_keychain_add() {
    local key="$1"
    [ -z "$key" ] && { echo "error:missing_key_path"; return 1; }
    key="${key/#\~/$HOME}"
    if [ ! -f "$key" ]; then
        echo "error:key_not_found:$key"
        return 1
    fi

    _ensure_ssh_agent

    # Add key to macOS keychain (-K stores passphrase in keychain, --apple-use-keychain on newer macOS)
    if ssh-add --apple-use-keychain "$key" 2>/dev/null; then
        _log "keychain-add: added $key via --apple-use-keychain"
        echo "ok:keychain_added:$key"
    elif ssh-add -K "$key" 2>/dev/null; then
        _log "keychain-add: added $key via -K"
        echo "ok:keychain_added:$key"
    else
        _log "keychain-add: failed for $key"
        echo "error:keychain_add_failed:$key"
        return 1
    fi
}

_ensure_key_unlocked() {
    # Before attempting SSH, make sure the key is usable.
    # If the key has a passphrase and BatchMode fails, try adding to keychain.
    local user="$1" ip="$2" key="$3"
    [ -z "$key" ] || [ ! -f "$key" ] && return 0

    # Quick test: can we connect in BatchMode?
    # Timeouts sized for up to ~1s RTT (VPN overseas, WifiMan to distant
    # sites, satellite): SSH handshake at 1s RTT needs ~8s of pure network
    # overhead. alarm=25 + ConnectTimeout=15 gives a comfortable margin
    # without making offline-host detection painfully slow (still bounded
    # at 25s worst case).
    if perl -e 'alarm 25; exec @ARGV' \
        ssh -o ConnectTimeout=15 \
        -o "StrictHostKeyChecking=accept-new" \
        -o "UserKnownHostsFile=$AF_KNOWN_HOSTS" \
        -o BatchMode=yes \
        -i "$key" "${user}@${ip}" "echo ok" >/dev/null 2>&1; then
        return 0
    fi

    # BatchMode failed — key likely needs passphrase. Try keychain.
    _log "key $key needs passphrase for ${user}@${ip}, attempting keychain add"
    _ensure_ssh_agent
    ssh-add --apple-use-keychain "$key" 2>/dev/null || ssh-add -K "$key" 2>/dev/null
}

# ─── Core helpers ────────────────────────────────────────────────────────────

_alive() {
    # Timeout ls to avoid hanging on stale mounts (macFUSE can block indefinitely)
    # macOS has no `timeout` — use perl one-liner as portable alternative
    # Reduced to 2 seconds for faster stale mount detection
    perl -e 'alarm 2; exec @ARGV' ls "$1" >/dev/null 2>&1
}

_kill_mount() {
    local mp="$1"
    # Try graceful first, then force
    umount "$mp" 2>/dev/null
    sleep 0.5
    _force_unmount "$mp"
    umount -f "$mp" 2>/dev/null
    # Kill any sshfs process for this mount — use fixed-string grep to prevent injection
    local bn
    bn="$(basename "$mp")"
    pgrep -f "sshfs" | while read -r pid; do
        # Verify the process command line actually references our mount point
        local cmd
        cmd="$(ps -p "$pid" -o args= 2>/dev/null)"
        if echo " $cmd " | grep -qF " $mp "; then
            kill "$pid" 2>/dev/null
        fi
    done
    # Clean up empty mount dir (but not the base ~/workstation)
    local base
    base="$(_json_raw mount_base)"
    [ "$mp" != "$base" ] && rmdir "$mp" 2>/dev/null
}

_is_stale() {
    local mp="$1"
    # Mount exists in mount table but ls hangs or fails
    mount | grep -qF " on $mp " || return 1
    ! _alive "$mp"
}

_reachable() {
    # Quick ping check with 2s timeout
    local ip="$1"
    [ -z "$ip" ] && return 1
    _ping_host "$ip" >/dev/null 2>&1
}

# Measure round-trip time in milliseconds for a single ping. Echoes the
# integer ms on success, empty on failure (so `[ -n "$rtt" ]` is a valid
# success check). Used to enrich the smart-endpoint cache with live
# latency data — turns `endpoint-cache-show` into a real diagnostic
# ("LAN: 4ms vs VPN: 82ms") instead of the placeholder "0" everywhere.
# Does NOT change endpoint selection policy — we still prefer priority
# order (LAN → VPN → extras → mDNS). RTT is informational for now; a
# future "prefer fastest" mode can consume it without re-plumbing.
_ping_rtt() {
    local ip="$1"
    [ -z "$ip" ] && return 1
    local out
    out="$(_ping_host "$ip")"
    [ -z "$out" ] && return 1
    # Extract `time=X.Y ms` — value ranges 0.001 to 2000+. Round to int ms.
    echo "$out" | awk '
        /time=/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^time=/) {
                    sub("time=", "", $i)
                    printf "%d\n", $i + 0.5
                    exit
                }
            }
        }
    '
}

_ssh_ok() {
    # Quick SSH connectivity check (faster than full mount)
    # Uses dedicated known_hosts and accept-new for TOFU.
    # Timeouts match _ensure_key_unlocked — sized for up to ~1s RTT links
    # (overseas VPN, WifiMan, satellite). Shorter timeouts silently reject
    # healthy high-latency endpoints as "unreachable" even though sshfs
    # itself would have connected fine.
    local user="$1" ip="$2" key="$3"
    perl -e 'alarm 25; exec @ARGV' \
        ssh -o ConnectTimeout=15 \
        -o "StrictHostKeyChecking=accept-new" \
        -o "UserKnownHostsFile=$AF_KNOWN_HOSTS" \
        -o BatchMode=yes \
        -i "$key" "${user}@${ip}" "echo ok" 2>/dev/null | grep -q "ok"
}

# ─── Wake-on-LAN ────────────────────────────────────────────────────────────

_send_wol() {
    local mac="$1" broadcast="${2:-255.255.255.255}" target_ip="${3:-}"
    [ -z "$mac" ] && { echo "no_mac"; return 1; }

    # Validate MAC format before passing to python
    local clean_mac
    clean_mac="$(echo "$mac" | tr -d ':-')"
    if ! echo "$clean_mac" | grep -qE '^[0-9a-fA-F]{12}$'; then
        echo "invalid_mac"
        return 1
    fi

    # Build magic packet using validated hex string via sys.argv (not interpolation).
    # Send to multiple addresses AND multiple times for WiFi reliability:
    #   * subnet broadcast (standard path; hits all devices on the /24 wire)
    #   * 255.255.255.255 (limited broadcast; some APs forward this better)
    #   * target_ip directly (unicast — when ARP entry is still cached, some
    #     consumer APs deliver to sleeping clients this way even though the
    #     client's L3 stack is down)
    # 3 rounds with 100ms gap beats typical WiFi packet-loss bursts.
    python3 -c "
import socket, sys, time
mac_hex = sys.argv[1]
broadcast = sys.argv[2]
target_ip = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
data = b'\xff' * 6 + bytes.fromhex(mac_hex) * 16
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
targets = [(broadcast, 9), (broadcast, 7), ('255.255.255.255', 9), ('255.255.255.255', 7)]
if target_ip and target_ip not in (broadcast, '255.255.255.255'):
    targets.append((target_ip, 9))
    targets.append((target_ip, 7))
for _ in range(3):
    for addr in targets:
        try:
            sock.sendto(data, addr)
        except OSError:
            pass
    time.sleep(0.1)
sock.close()
print('wol_sent')
" "$clean_mac" "$broadcast" "$target_ip" 2>/dev/null
}

# Send a Wake-on-LAN magic packet to the workstation's MAC.
# Broadcasts on the /24 derived from `lan_ip` when present, falling back to
# 255.255.255.255. We send to UDP ports 9 AND 7 because some motherboards
# only listen on one (port 9 is the modern default, 7 is legacy "echo").
# MAC is sanitized to hex-only and validated to 12 chars before being passed
# to the Python sender via argv — never interpolated into source.
_do_wol() {
    local ws_name="$1"
    _read_workstation "$ws_name"
    _log "wol: sending to $ws_name"

    if [ -z "$ws_mac_address" ]; then
        _log "wol: no MAC for $ws_name"
        echo "no_mac:$ws_name"
        return 1
    fi

    # Determine broadcast address from LAN IP
    local broadcast="255.255.255.255"
    if [ -n "$ws_lan_ip" ]; then
        # Derive broadcast from IP (assume /24)
        local prefix="${ws_lan_ip%.*}"
        broadcast="${prefix}.255"
    fi

    # Pass target IP as third arg — _send_wol also sends a unicast packet
    # to it so APs that drop broadcast to sleeping clients still deliver.
    _send_wol "$ws_mac_address" "$broadcast" "$ws_lan_ip"

    # Also try sending via VPN broadcast if VPN IP exists
    if [ -n "$ws_vpn_ip" ]; then
        local vpn_prefix="${ws_vpn_ip%.*}"
        _send_wol "$ws_mac_address" "${vpn_prefix}.255" "$ws_vpn_ip" >/dev/null 2>&1
    fi
}

_wol_and_wait() {
    local ws_name="$1" max_wait="${2:-60}"
    _read_workstation "$ws_name"

    echo "wol_sending:$ws_name"
    _do_wol "$ws_name"

    # Wait for host to come online
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        if _reachable "$ws_lan_ip" || _reachable "$ws_vpn_ip"; then
            # Give SSH a moment to start
            sleep 3
            echo "wol_online:$ws_name:${elapsed}s"
            return 0
        fi
        echo "wol_waiting:$ws_name:${elapsed}s"
    done
    echo "wol_timeout:$ws_name"
    return 1
}

# Panic commands (network-loss recovery) are implemented inline in the case
# dispatch below (`panic-unmount-all` / `panic-check`). Earlier drafts had
# separate `_do_panic_*` helpers here — removed because the inline versions
# are the ones actually called, and the helpers duplicated the logic with a
# subshell-scoping bug on `stale_found` (pipeline `while` runs in a subshell
# so the flag never propagated back to the caller).

# Rewrite an SMB UNC URI to point at a specific user + host while keeping the share suffix.
# Uses pure bash parameter expansion (no sed) so user-supplied share strings
# containing sed-meta characters cannot break the substitution.
# Input:  //olduser@oldhost/Share/Path  new_user  new_host
# Output: //new_user@new_host/Share/Path
_smb_rewrite_host() {
    local share="$1" new_user="$2" new_host="$3"
    local after="${share#//}"        # strip leading // → user@host/share/path
    local path_suffix=""
    if [[ "$after" == */* ]]; then
        path_suffix="/${after#*/}"    # everything from first / onward
    fi
    printf '//%s@%s%s\n' "$new_user" "$new_host" "$path_suffix"
}

# ─── Mount / Unmount / Status ────────────────────────────────────────────────

# SMB counterpart of `_do_mount`. Same LAN→VPN→WoL resilience chain, but uses
# macOS-native `mount_smbfs` (no FUSE backend required) and rewrites the
# user-configured UNC share (`//user@host/Share`) to point at whichever
# endpoint is reachable via `_smb_rewrite_host` (pure bash, no sed). Callers
# reach this through `_do_mount` dispatching on `ws_protocol=smb` — not from
# the CLI directly. Success lines use `mounted_lan:`/`mounted_vpn:`/... same
# prefix convention as SSHFS so menu/MCP parsers handle both protocols
# uniformly.
_do_smb_mount() {
    local ws_name="$1" disk_letter="$2"
    _log "smb_mount: start $ws_name/$disk_letter"

    _read_workstation "$ws_name"
    _read_disk "$ws_name" "$disk_letter"

    # Validate SMB share is configured
    if [ -z "$ws_smb_share" ]; then
        _log "smb_mount: no smb_share configured for $ws_name"
        echo "error:smb_share_not_configured"
        return 1
    fi

    local mp
    mp="$(_mount_point "$ws_name" "$disk_letter")"

    # Validate mount point is not a file
    if [ -e "$mp" ] && [ ! -d "$mp" ]; then
        echo "error:mount_point_not_dir:$mp"
        return 1
    fi

    mkdir -p "$mp"

    # Kill stale mount if present
    if mount | grep -qF " on $mp "; then
        _kill_mount "$mp"
        sleep 1
    fi

    local last_err=""
    local lan_reachable=0
    local vpn_reachable=0

    # Try LAN first
    if [ -n "$ws_lan_ip" ]; then
        if _reachable "$ws_lan_ip"; then
            lan_reachable=1
            _log "smb_mount: LAN reachable $ws_lan_ip"
            # Extract user and share from smb_share format: //user@host/share
            local smb_with_ip
            smb_with_ip="$(_smb_rewrite_host "$ws_smb_share" "$ws_user" "$ws_lan_ip")"
            last_err=$(mount_smbfs "$smb_with_ip" "$mp" 2>&1)
            if _alive "$mp"; then
                _log "smb_mount: success LAN $ws_name/$disk_letter at $mp"
                echo "mounted_lan:$mp"
                return 0
            fi
            [ -n "$last_err" ] || last_err="mount_smbfs succeeded but volume not accessible"
            _log "smb_mount: LAN mount failed: $last_err"
        else
            last_err="LAN host ${ws_lan_ip} not reachable (ping failed)"
            _log "smb_mount: $last_err"
        fi
    fi

    # Try VPN
    if [ -n "$ws_vpn_ip" ]; then
        if _reachable "$ws_vpn_ip"; then
            vpn_reachable=1
            _log "smb_mount: VPN reachable $ws_vpn_ip"
            _kill_mount "$mp" 2>/dev/null; sleep 1; mkdir -p "$mp"
            local smb_with_ip
            smb_with_ip="$(_smb_rewrite_host "$ws_smb_share" "$ws_user" "$ws_vpn_ip")"
            last_err=$(mount_smbfs "$smb_with_ip" "$mp" 2>&1)
            if _alive "$mp"; then
                _log "smb_mount: success VPN $ws_name/$disk_letter at $mp"
                echo "mounted_vpn:$mp"
                return 0
            fi
            [ -n "$last_err" ] || last_err="mount_smbfs succeeded but volume not accessible"
            _log "smb_mount: VPN mount failed: $last_err"
        else
            [ -z "$last_err" ] && last_err="VPN host ${ws_vpn_ip} not reachable"
            _log "smb_mount: VPN not reachable $ws_vpn_ip"
        fi
    fi

    # Try Wake-on-LAN if MAC is configured and host was unreachable
    if [ -n "$ws_mac_address" ] && [ "$lan_reachable" -eq 0 ] && [ "$vpn_reachable" -eq 0 ]; then
        _log "smb_mount: attempting WoL for $ws_name"
        echo "trying_wol:$mp"
        if _wol_and_wait "$ws_name" 60; then
            if [ -n "$ws_lan_ip" ] && _reachable "$ws_lan_ip"; then
                local smb_with_ip
                smb_with_ip="$(_smb_rewrite_host "$ws_smb_share" "$ws_user" "$ws_lan_ip")"
                last_err=$(mount_smbfs "$smb_with_ip" "$mp" 2>&1)
                if _alive "$mp"; then
                    _log "smb_mount: success WoL+LAN $ws_name/$disk_letter at $mp"
                    echo "mounted_wol_lan:$mp"
                    return 0
                fi
            fi
            if [ -n "$ws_vpn_ip" ] && _reachable "$ws_vpn_ip"; then
                local smb_with_ip
                smb_with_ip="$(_smb_rewrite_host "$ws_smb_share" "$ws_user" "$ws_vpn_ip")"
                last_err=$(mount_smbfs "$smb_with_ip" "$mp" 2>&1)
                if _alive "$mp"; then
                    _log "smb_mount: success WoL+VPN $ws_name/$disk_letter at $mp"
                    echo "mounted_wol_vpn:$mp"
                    return 0
                fi
            fi
            last_err="WoL sent but mount still failed after wake"
            _log "smb_mount: $last_err"
        else
            last_err="WoL sent but host did not come online within 60s"
            _log "smb_mount: $last_err"
        fi
    fi

    # Build diagnostic error message
    if [ -z "$ws_lan_ip" ] && [ -z "$ws_vpn_ip" ]; then
        last_err="No IP configured for this workstation"
    fi

    # Clean up failed mount
    rmdir "$mp" 2>/dev/null
    _log "smb_mount: failed $ws_name/$disk_letter at $mp: $last_err"
    echo "failed:$mp:$last_err"
    return 1
}

# Mount a single disk for a workstation. Handles the full resilience flow:
#   1. Detect which FUSE backend is installed (macFUSE vs FUSE-T); the two
#      ship different `sshfs` binaries in different paths and must be
#      selected at runtime — the user can have both installed.
#   2. Dispatch to `_do_smb_mount` if the workstation's protocol is SMB.
#   3. Validate the mount point is a directory (not a file) and clean up any
#      existing stale mount at that path.
#   4. Try LAN IP → VPN IP → optionally WoL + retry, logging the attempt
#      chain so the user can see why a mount ultimately failed.
# Emits a single-line status on stdout: `mounted_lan:<mp>`, `mounted_vpn:<mp>`,
# `mounted_wol_lan:<mp>`, `mounted_wol_vpn:<mp>`, or `failed:<mp>:<reason>`.
# Caller (CLI / main.m / MCP) parses the prefix to update UI state.
_do_mount() {
    local ws_name="$1" disk_letter="$2"
    _log "mount: start $ws_name/$disk_letter"

    # Detect FUSE backend and find sshfs binary
    local fuse_backend
    fuse_backend="$(_detect_fuse_backend)"
    if [ "$fuse_backend" = "none" ]; then
        _log "mount: no FUSE backend found"
        if [ "$AF_OS" = "Darwin" ]; then
            echo "error:no_fuse_backend:Install macFUSE (osxfuse.github.io) or FUSE-T (brew install fuse-t fuse-t-sshfs)"
        else
            echo "error:no_fuse_backend:Install sshfs (Arch: sudo pacman -S sshfs · Debian/Ubuntu: sudo apt install sshfs · Fedora: sudo dnf install fuse-sshfs)"
        fi
        return 1
    fi

    local sshfs_bin
    sshfs_bin="$(_find_sshfs_binary "$fuse_backend")"
    if [ -z "$sshfs_bin" ]; then
        _log "mount: sshfs binary not found (backend=$fuse_backend)"
        echo "error:sshfs_not_found"
        return 1
    fi
    _log "mount: using $sshfs_bin (backend=$fuse_backend)"

    _read_workstation "$ws_name"
    _read_disk "$ws_name" "$disk_letter"

    # Protocol branching: SMB vs SSHFS
    if [ "$ws_protocol" = "smb" ]; then
        _do_smb_mount "$ws_name" "$disk_letter"
        return $?
    fi

    _read_ssh_opts
    local sopts=("${SSH_OPTS[@]}")

    # if a trusted host-key fingerprint is stored, pick a
    # verified endpoint (lan_ip, vpn_ip, additional_ips[], or <name>.local
    # mDNS — whichever is reachable AND matches the fingerprint). This gives
    # cross-network machine identity: the same server found correctly from
    # Studio WiFi, home WiFi, VPN, or Tailscale. If nothing matches, refuse
    # rather than silently connecting to a rotated or unverified host.
    if [ -n "$ws_host_key_sha256" ]; then
        local _picked
        _picked="$(_pick_endpoint "$ws_name")"
        if [ -z "$_picked" ]; then
            _log "mount: no endpoint matches stored host key ($ws_host_key_sha256) — refusing"
            echo "error:host_key_mismatch:no_verified_endpoint"
            return 1
        fi
        _log "mount: host-key-verified endpoint $_picked (lan=$ws_lan_ip vpn=$ws_vpn_ip)"
        ws_lan_ip="$_picked"
    fi

    local mp
    mp="$(_mount_point "$ws_name" "$disk_letter")"

    # Validate mount point is not a file
    if [ -e "$mp" ] && [ ! -d "$mp" ]; then
        echo "error:mount_point_not_dir:$mp"
        return 1
    fi

    mkdir -p "$mp"

    # Kill stale mount if present
    if mount | grep -qF " on $mp "; then
        _kill_mount "$mp"
        sleep 1
    fi

    local volname="${ws_name}-${disk_letter}"
    local ssh_common=(-o "IdentityFile=$ws_ssh_key" -o "StrictHostKeyChecking=accept-new" -o "UserKnownHostsFile=$AF_KNOWN_HOSTS")

    local last_err=""
    local lan_reachable=0
    local vpn_reachable=0

    # Ensure SSH key is unlocked (keychain integration)
    local _key_ip="${ws_lan_ip:-$ws_vpn_ip}"
    if [ -n "$_key_ip" ] && _reachable "$_key_ip"; then
        _ensure_key_unlocked "$ws_user" "$_key_ip" "$ws_ssh_key"
    fi

    # Try LAN first
    if [ -n "$ws_lan_ip" ]; then
        if _reachable "$ws_lan_ip"; then
            lan_reachable=1
            _log "mount: LAN reachable $ws_lan_ip"
            if _ssh_ok "$ws_user" "$ws_lan_ip" "$ws_ssh_key"; then
                last_err=$("$sshfs_bin" "${ws_user}@${ws_lan_ip}:${disk_remote_path}" "$mp" \
                    -o "volname=$volname" "${ssh_common[@]}" "${sopts[@]}" 2>&1)
                if _alive "$mp"; then
                    _log "mount: success LAN $ws_name/$disk_letter at $mp"
                    _maybe_learn_host_key "$ws_name" "$ws_lan_ip"
                    _exclude_from_indexing "$mp"
                    echo "mounted_lan:$mp"
                    return 0
                fi
                [ -n "$last_err" ] || last_err="sshfs mounted but volume not accessible"
                _log "mount: LAN sshfs failed: $last_err"
            else
                last_err="SSH connection failed to ${ws_lan_ip} (key: $ws_ssh_key)"
                _log "mount: $last_err"
            fi
        else
            last_err="LAN host ${ws_lan_ip} not reachable (ping failed)"
            _log "mount: $last_err"
        fi
    fi

    # Try VPN
    if [ -n "$ws_vpn_ip" ]; then
        if _reachable "$ws_vpn_ip"; then
            vpn_reachable=1
            _log "mount: VPN reachable $ws_vpn_ip"
            _kill_mount "$mp" 2>/dev/null; sleep 1; mkdir -p "$mp"
            if _ssh_ok "$ws_user" "$ws_vpn_ip" "$ws_ssh_key"; then
                last_err=$("$sshfs_bin" "${ws_user}@${ws_vpn_ip}:${disk_remote_path}" "$mp" \
                    -o "volname=$volname" "${ssh_common[@]}" "${sopts[@]}" 2>&1)
                if _alive "$mp"; then
                    _log "mount: success VPN $ws_name/$disk_letter at $mp"
                    _maybe_learn_host_key "$ws_name" "$ws_vpn_ip"
                    _exclude_from_indexing "$mp"
                    echo "mounted_vpn:$mp"
                    return 0
                fi
                [ -n "$last_err" ] || last_err="sshfs mounted but volume not accessible"
                _log "mount: VPN sshfs failed: $last_err"
            else
                last_err="SSH connection failed to ${ws_vpn_ip} (key: $ws_ssh_key)"
                _log "mount: $last_err"
            fi
        else
            [ -z "$last_err" ] && last_err="VPN host ${ws_vpn_ip} not reachable"
            _log "mount: VPN not reachable $ws_vpn_ip"
        fi
    fi

    # Try Wake-on-LAN if MAC is configured and host was unreachable
    if [ -n "$ws_mac_address" ] && [ "$lan_reachable" -eq 0 ] && [ "$vpn_reachable" -eq 0 ]; then
        _log "mount: attempting WoL for $ws_name"
        echo "trying_wol:$mp"
        if _wol_and_wait "$ws_name" 60; then
            # Ensure key is unlocked after WoL wake
            local _wol_ip="${ws_lan_ip:-$ws_vpn_ip}"
            [ -n "$_wol_ip" ] && _ensure_key_unlocked "$ws_user" "$_wol_ip" "$ws_ssh_key"

            if [ -n "$ws_lan_ip" ] && _reachable "$ws_lan_ip"; then
                last_err=$("$sshfs_bin" "${ws_user}@${ws_lan_ip}:${disk_remote_path}" "$mp" \
                    -o "volname=$volname" "${ssh_common[@]}" "${sopts[@]}" 2>&1)
                if _alive "$mp"; then
                    _log "mount: success WoL+LAN $ws_name/$disk_letter at $mp"
                    _maybe_learn_host_key "$ws_name" "$ws_lan_ip"
                    _exclude_from_indexing "$mp"
                    echo "mounted_wol_lan:$mp"
                    return 0
                fi
            fi
            if [ -n "$ws_vpn_ip" ] && _reachable "$ws_vpn_ip"; then
                last_err=$("$sshfs_bin" "${ws_user}@${ws_vpn_ip}:${disk_remote_path}" "$mp" \
                    -o "volname=$volname" "${ssh_common[@]}" "${sopts[@]}" 2>&1)
                if _alive "$mp"; then
                    _log "mount: success WoL+VPN $ws_name/$disk_letter at $mp"
                    _maybe_learn_host_key "$ws_name" "$ws_vpn_ip"
                    _exclude_from_indexing "$mp"
                    echo "mounted_wol_vpn:$mp"
                    return 0
                fi
            fi
            last_err="WoL sent but mount still failed after wake"
            _log "mount: $last_err"
        else
            last_err="WoL sent but host did not come online within 60s"
            _log "mount: $last_err"
        fi
    fi

    # Build diagnostic error message
    if [ -z "$ws_lan_ip" ] && [ -z "$ws_vpn_ip" ]; then
        last_err="No IP configured for this workstation"
    fi

    # Clean up failed mount
    rmdir "$mp" 2>/dev/null
    _log "mount: failed $ws_name/$disk_letter at $mp: $last_err"
    echo "failed:$mp:$last_err"
    return 1
}

_do_unmount() {
    local ws_name="$1" disk_letter="$2"
    local mp
    mp="$(_mount_point "$ws_name" "$disk_letter")"
    _log "unmount: $ws_name/$disk_letter at $mp"
    _kill_mount "$mp"
    _log "unmount: done $mp"
    echo "unmounted:$mp"
}

_do_status() {
    # Read-only state probe. The menu bar polls this every few seconds plus
    # the MCP server queries it on demand — logging each call floods the log
    # with hundreds of identical "status: unmounted" lines per minute,
    # making `autofuse log` useless for finding real events.
    # Log **transitions only** via a tiny per-disk cache under
    # ~/.config/autofuse/.status-cache/. Events like mount/unmount/heal/panic
    # still log their own lines, so the audit trail stays complete.
    local ws_name="$1" disk_letter="$2"
    local mp new_state
    mp="$(_mount_point "$ws_name" "$disk_letter")"

    # Check computed mount point
    if mount | grep -qF " on $mp "; then
        if _alive "$mp"; then
            new_state="mounted:$mp"
            _log_if_changed "$ws_name" "$disk_letter" "$new_state"
            echo "$new_state"; return 0
        fi
        new_state="stale:$mp"
        _log_if_changed "$ws_name" "$disk_letter" "$new_state"
        echo "$new_state"; return 0
    fi

    # Check legacy mount point (~/workstation without disk subfolder)
    _read_workstation "$ws_name"
    _read_disk "$ws_name" "$disk_letter"
    local base
    base="$(_json_raw mount_base)"
    # Bug fix: `grep -q | grep -q` silently always fails because -q suppresses stdout.
    # We want "a line mentions disk_remote_path AND is mounted on $base".
    if mount | grep -F "${disk_remote_path}" | grep -qF "on ${base} "; then
        if _alive "$base"; then
            new_state="mounted:$base"
            _log_if_changed "$ws_name" "$disk_letter" "$new_state"
            echo "$new_state"; return 0
        fi
        new_state="stale:$base"
        _log_if_changed "$ws_name" "$disk_letter" "$new_state"
        echo "$new_state"; return 0
    fi

    new_state="unmounted:$mp"
    _log_if_changed "$ws_name" "$disk_letter" "$new_state"
    echo "$new_state"
}

# Write a status line to the audit log only when it differs from the last
# state seen for this disk. Keeps the log focused on transitions, not polls.
# Cache dir mirrors the config dir so cleanup is a single `rm -rf`.
_log_if_changed() {
    local _ws="$1" _disk="$2" _state="$3"
    local _cache_dir="$HOME/.config/autofuse/.status-cache"
    mkdir -p "$_cache_dir" 2>/dev/null
    local _cache_file="${_cache_dir}/${_ws}__${_disk}"
    local _prev=""
    [ -f "$_cache_file" ] && _prev="$(cat "$_cache_file" 2>/dev/null)"
    if [ "$_prev" != "$_state" ]; then
        _log "status: ${_state%%:*} ${_ws}/${_disk} at ${_state#*:}"
        printf '%s' "$_state" > "$_cache_file"
    fi
}

# ─── Heal: auto-recover stale mounts ────────────────────────────────────────

# One-shot recovery for a single disk. Called by the menu-bar auto-heal timer
# and the `heal` / `heal-all` CLI. The flow is:
#   1. Ask `_do_status` — this distinguishes stale (in mount table but `ls`
#      hangs) from genuinely unmounted from healthy. Crucially, it uses the
#      2s `_alive` timeout so a truly dead mount doesn't hang this call too.
#   2. If stale, force-kill the mount (SIGKILL on the sshfs process plus
#      `diskutil unmount force`) and re-run `_do_mount`. Remounting after a
#      kill is what actually restores usability — simply unmounting leaves
#      `~/workstation-C` empty until the user manually reconnects.
#   3. If healthy or unmounted, emit a status line and do nothing.
_do_heal() {
    local ws_name="$1" disk_letter="$2"
    _log "heal: checking $ws_name/$disk_letter"
    local status_line
    status_line="$(_do_status "$ws_name" "$disk_letter")"
    local status="${status_line%%:*}"

    case "$status" in
        stale)
            # Unmount stale, remount
            local mp="${status_line#*:}"
            _log "heal: stale mount detected at $mp, recovering"
            echo "healing_stale:$mp"
            _kill_mount "$mp"
            sleep 1
            _do_mount "$ws_name" "$disk_letter"
            ;;
        mounted)
            _log "heal: healthy $ws_name/$disk_letter"
            echo "healthy:${status_line#*:}"
            ;;
        unmounted)
            _log "heal: not mounted $ws_name/$disk_letter"
            echo "not_mounted:${status_line#*:}"
            ;;
    esac
}

# ─── Ping check (reachability without mounting) ─────────────────────────────

_do_ping() {
    local ws_name="$1"
    _read_workstation "$ws_name"

    local result="offline"
    if [ -n "$ws_lan_ip" ] && _reachable "$ws_lan_ip"; then
        result="lan:$ws_lan_ip"
    elif [ -n "$ws_vpn_ip" ] && _reachable "$ws_vpn_ip"; then
        result="vpn:$ws_vpn_ip"
    fi
    echo "${ws_name}|${result}"
}

# Comprehensive workstation diagnostic — one-shot report combining every
# signal AutoFuse collects about a host. Use when a mount fails or feels
# slow and you want to know "is the network wrong, is SSH wrong, is the
# host-key wrong, is the disk full, or is it just Windows OpenSSH again?".
# Usage: diagnose <ws>
# Output is human-readable (with blank lines + section headers) rather
# than pipe-delimited — this is a read-only tool for humans and LLMs to
# interpret, not for other mount.sh commands to parse.
_do_diagnose() {
    local ws_name="$1"
    [ -z "$ws_name" ] && { echo "error:missing_workstation_name"; return 1; }
    _read_workstation "$ws_name"
    if [ -z "$ws_name" ] || [ -z "$ws_user" ]; then
        echo "error:workstation_not_found:${1}"
        return 1
    fi
    local _expected="$ws_host_key_sha256"

    echo "=== Diagnostic: $ws_name ==="
    echo ""
    echo "User:         $ws_user"
    echo "SSH key:      $ws_ssh_key"
    echo "Host key:     ${_expected:-<none stored (TOFU will capture on first mount)>}"
    echo ""
    echo "Endpoints:"

    local _ep _kind _reach _rtt _ssh_state _smb_state _key_state _current_sha
    while IFS= read -r _ep; do
        [ -z "$_ep" ] && continue

        # Classify endpoint origin for the report column
        if [ -n "$ws_lan_ip" ] && [ "$_ep" = "$ws_lan_ip" ]; then
            _kind="LAN"
        elif [ -n "$ws_vpn_ip" ] && [ "$_ep" = "$ws_vpn_ip" ]; then
            _kind="VPN"
        elif [[ "$_ep" == *.local ]]; then
            _kind="mDNS"
        else
            _kind="extra"
        fi

        # Reachability + RTT
        if _reachable "$_ep" 2>/dev/null; then
            _rtt="$(_ping_rtt "$_ep")"
            _reach="reachable (${_rtt:-?}ms)"
        else
            _reach="unreachable"
        fi

        # Port checks — only if reachable; otherwise n/a to avoid a 2s timeout per port
        _ssh_state="n/a"
        _smb_state="n/a"
        if [[ "$_reach" == reachable* ]]; then
            # nc -w has built-in timeout (seconds). Avoiding perl+alarm
            # here keeps the report clean — SIGALRM propagation produces
            # 'Alarm clock: 14' noise on stderr that's hard to suppress
            # without subshell wrapping.
            if nc -z -w 2 "$_ep" 22 >/dev/null 2>&1; then
                _ssh_state="yes"
            else
                _ssh_state="no"
            fi
            if nc -z -w 2 "$_ep" 445 >/dev/null 2>&1; then
                _smb_state="yes"
            else
                _smb_state="no"
            fi
        fi

        # Host-key match — only if reachable+ssh and fingerprint stored
        if [ -z "$_expected" ]; then
            _key_state="no_fingerprint"
        elif [[ "$_reach" != reachable* ]] || [ "$_ssh_state" != "yes" ]; then
            _key_state="n/a"
        else
            _current_sha="$(_get_remote_host_key_sha256 "$_ep" 2>/dev/null)"
            if [ -z "$_current_sha" ]; then
                _key_state="keyscan_failed"
            elif [ "$_current_sha" = "$_expected" ]; then
                _key_state="match"
            else
                _key_state="MISMATCH"
            fi
        fi

        printf "  %-5s %-22s  %-24s  ssh:%-3s smb:%-3s key:%s\n" \
            "$_kind" "$_ep" "$_reach" "$_ssh_state" "$_smb_state" "$_key_state"
    done < <(_list_endpoints "$ws_name")

    echo ""
    echo "Disks:"
    local _state_line _letter _label _rpath _mount_state _mp
    while IFS='|' read -r _letter _label _rpath; do
        [ -z "$_letter" ] && continue
        _state_line="$(_do_status "$ws_name" "$_letter" 2>/dev/null)"
        _mount_state="${_state_line%%:*}"
        _mp="${_state_line#*:}"
        printf "  %s/%s  %-10s  %-20s  %s\n" \
            "$ws_name" "$_letter" "$_mount_state" "$_label" "$_mp"
    done < <(_json_raw disks "$ws_name")

    echo ""
    echo "Recommendation:"
    local _best
    _best="$(_pick_endpoint "$ws_name" 2>/dev/null)"
    if [ -n "$_best" ]; then
        echo "  Best endpoint: $_best"
    else
        echo "  No endpoint passes reachability + host-key check."
        echo "  Likely causes: workstation off, wrong network, or impersonation."
    fi
    echo ""
    echo "  Throughput hint: Windows hosts running OpenSSH cap SSH at"
    echo "  ~80 Mbps per connection regardless of network capacity. If"
    echo "  your workstation is Windows and you need faster transfers,"
    echo "  set \"protocol\": \"smb\" in this workstation's config for"
    echo "  400+ Mbps native SMB."
}

# ─── Health Dashboard ──────────────────────────────────────────────────────

_measure_latency() {
    local mp="$1"
    local start_ms end_ms elapsed_ms
    start_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
    perl -e 'alarm 3; exec @ARGV' ls "$mp" >/dev/null 2>&1
    local rc=$?
    end_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
    if [ $rc -ne 0 ]; then
        echo "-1"
        return
    fi
    elapsed_ms=$((end_ms - start_ms))
    echo "$elapsed_ms"
}

_measure_throughput() {
    local mp="$1"
    local tmpfile="$mp/.autofuse_health"
    local start_ms end_ms elapsed_ms throughput_kbps
    start_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
    dd if=/dev/zero of="$tmpfile" bs=65536 count=1 >/dev/null 2>&1
    local rc=$?
    end_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
    rm -f "$tmpfile" 2>/dev/null
    if [ $rc -ne 0 ]; then
        echo "0"
        return
    fi
    elapsed_ms=$((end_ms - start_ms))
    if [ "$elapsed_ms" -le 0 ]; then
        elapsed_ms=1
    fi
    # 64KB written in elapsed_ms => KB/s = 64 * 1000 / elapsed_ms
    throughput_kbps=$(( 64 * 1000 / elapsed_ms ))
    echo "$throughput_kbps"
}

_measure_uptime() {
    local mp="$1"
    local mount_epoch now_epoch
    mount_epoch=$(stat -f %m "$mp" 2>/dev/null)
    if [ -z "$mount_epoch" ]; then
        echo "0"
        return
    fi
    now_epoch=$(date +%s)
    echo $(( now_epoch - mount_epoch ))
}

_classify_status() {
    local latency="$1"
    if [ "$latency" -lt 0 ] 2>/dev/null; then
        echo "critical"
    elif [ "$latency" -lt 100 ] 2>/dev/null; then
        echo "healthy"
    elif [ "$latency" -le 500 ] 2>/dev/null; then
        echo "degraded"
    else
        echo "critical"
    fi
}

_do_health() {
    local ws_name="$1" disk_letter="$2"
    local mp
    mp="$(_mount_point "$ws_name" "$disk_letter")"

    local status_line
    status_line="$(_do_status "$ws_name" "$disk_letter")"
    local status_prefix="${status_line%%:*}"

    case "$status_prefix" in
        unmounted)
            echo "${ws_name}|${disk_letter}|unmounted|0|0|0|"
            return
            ;;
        stale)
            echo "${ws_name}|${disk_letter}|stale|0|0|0|${mp}"
            return
            ;;
        mounted)
            local actual_mp="${status_line#*:}"
            local latency throughput uptime_secs health_status
            latency=$(_measure_latency "$actual_mp")
            throughput=$(_measure_throughput "$actual_mp")
            uptime_secs=$(_measure_uptime "$actual_mp")
            health_status=$(_classify_status "$latency")
            # Clamp negative latency to 0 for display
            [ "$latency" -lt 0 ] 2>/dev/null && latency=0
            echo "${ws_name}|${disk_letter}|${health_status}|${latency}|${throughput}|${uptime_secs}|${actual_mp}"
            ;;
    esac
}

_do_health_all() {
    _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            _do_health "$name" "$dl"
        done
    done
}

_do_health_json() {
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < <(_do_health_all)

    python3 -c "
import json, sys

lines = sys.argv[1:]
result = []
for line in lines:
    parts = line.split('|')
    if len(parts) >= 7:
        result.append({
            'workstation': parts[0],
            'disk': parts[1],
            'status': parts[2],
            'latency_ms': int(parts[3]) if parts[3] else 0,
            'throughput_kbps': int(parts[4]) if parts[4] else 0,
            'uptime_secs': int(parts[5]) if parts[5] else 0,
            'mount_point': parts[6]
        })

print(json.dumps({'health': result}, indent=2))
" "${lines[@]}"
}

# ─── Config Export / Import ────────────────────────────────────────────────

_do_export_config() {
    local filter_ws="$1"
    python3 -c "
import json, sys, os
from datetime import datetime, timezone

config_path = sys.argv[1]
filter_ws = sys.argv[2] if len(sys.argv) > 2 else ''

with open(config_path) as f:
    cfg = json.load(f)

workstations = []
for w in cfg.get('workstations', []):
    if filter_ws and w['name'] != filter_ws:
        continue
    ws_export = {
        'name': w['name'],
        'lan_ip': w.get('lan_ip', ''),
        'vpn_ip': w.get('vpn_ip', ''),
        'disks': []
    }
    for d in w.get('disks', []):
        disk_obj = {
            'letter': d['letter'],
            'label': d.get('label', ''),
            'remote_path': d.get('remote_path', '')
        }
        if d.get('primary', False):
            disk_obj['primary'] = True
        ws_export['disks'].append(disk_obj)
    workstations.append(ws_export)

export_obj = {
    'autofuse_version': '4.0',
    'exported': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S'),
    'workstations': workstations,
    'note': 'Import with: autofuse import-config <file>'
}

print(json.dumps(export_obj, indent=2))
" "$CONFIG" "$filter_ws"
}

_do_import_config() {
    local import_file="$1"
    local interactive="${2:-yes}"

    if [ ! -f "$import_file" ]; then
        echo "error:file_not_found:$import_file"
        return 1
    fi

    # Validate JSON
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$import_file" 2>/dev/null; then
        echo "error:invalid_json:$import_file"
        return 1
    fi

    python3 -c "
import json, sys, os

config_path = sys.argv[1]
import_path = sys.argv[2]
interactive = sys.argv[3] == 'yes'

with open(config_path) as f:
    cfg = json.load(f)

with open(import_path) as f:
    imp = json.load(f)

existing_names = {w['name'] for w in cfg.get('workstations', [])}
imported = []
skipped = []

for w in imp.get('workstations', []):
    name = w.get('name', '')
    if not name:
        continue
    if name in existing_names:
        # In non-interactive mode, skip existing
        if not interactive:
            skipped.append(name)
            continue
        # Interactive mode: also skip (shell-level prompting handled externally)
        skipped.append(name)
        continue

    # Build workstation entry (no ssh_key or mac_address — user must set after import)
    ws_entry = {
        'name': name,
        'user': name,
        'lan_ip': w.get('lan_ip', ''),
        'vpn_ip': w.get('vpn_ip', ''),
        'ssh_key': '~/.ssh/id_ed25519',
        'disks': []
    }
    for d in w.get('disks', []):
        disk_entry = {
            'letter': d.get('letter', ''),
            'label': d.get('label', ''),
            'remote_path': d.get('remote_path', '')
        }
        if d.get('primary', False):
            disk_entry['primary'] = True
        ws_entry['disks'].append(disk_entry)

    cfg.setdefault('workstations', []).append(ws_entry)
    imported.append(f\"{name}:{len(ws_entry['disks'])}_disks\")

# Write updated config atomically: write to a temp file in the same dir,
# fsync, then os.replace so a crash mid-write cannot corrupt the real config.
# Matches the pattern used by learn-host-key. Output is post-processed to
# Apple NSJSONWritingPrettyPrinted style (\`\"key\" : value\`) so diffs stay
# tiny when the app re-saves this file later.
import tempfile, re
_text = re.sub(r'^(\s*\"[^\"]+\"):', r'\1 :', json.dumps(cfg, indent=2), flags=re.MULTILINE)
_dir = os.path.dirname(os.path.abspath(config_path)) or '.'
_tmp = tempfile.NamedTemporaryFile('w', delete=False, dir=_dir, prefix='.autofuse-import-')
_tmp.write(_text + '\n')
_tmp.flush()
os.fsync(_tmp.fileno())
_tmp.close()
os.chmod(_tmp.name, 0o600)
os.replace(_tmp.name, config_path)

for i in imported:
    print(f'imported:{i}')
for s in skipped:
    print(f'skipped:{s}:already_exists')

if not imported and not skipped:
    print('warning:no_workstations_in_file')
" "$CONFIG" "$import_file" "$interactive"
}

# ─── Command dispatch ───────────────────────────────────────────────────────

case "$1" in
list)
    _json_raw list_workstations
    ;;
disks)
    [ -z "$2" ] && { echo "error:missing_workstation_name"; exit 1; }
    _json_raw disks "$2"
    ;;
status)
    _do_status "$2" "$3"
    ;;
status-all)
    # Run every disk's status probe in parallel. Sequential was O(n) ×
    # _alive timeout (~2s each); with 3 disks on a slow tunnel that's 6s.
    # Parallel collapses total latency to max(per-disk probe) ≈ 2s.
    #
    # Note the process-substitution `< <(...)` for the outer list-workstations
    # loop: if we used a pipe, the `while` body runs in a subshell and the
    # background forks inside it escape the main shell's `wait`. That bug
    # shipped briefly earlier — now the while-loop is in the main shell,
    # so `wait` actually blocks until every probe completes.
    _status_all_tmpfile="$(mktemp /tmp/autofuse-statusall.XXXXXX)"
    while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            (
                result="$(_do_status "$name" "$dl")"
                echo "${name}|${dl}|${result}"
            ) >> "$_status_all_tmpfile" &
        done
    done < <(_json_raw list_workstations)
    wait
    # Sort keeps output stable (order doesn't depend on which probe finished
    # first) so callers see a consistent stream across invocations.
    sort "$_status_all_tmpfile"
    rm -f "$_status_all_tmpfile"
    ;;
mount)
    if [ -z "$3" ]; then
        _json_raw disks "$2" | while IFS='|' read -r letter label rpath; do
            _do_mount "$2" "$letter"
        done
    else
        _do_mount "$2" "$3"
    fi
    ;;
mount-all)
    _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            _do_mount "$name" "$dl"
        done
    done
    ;;
unmount)
    if [ -z "$3" ]; then
        _json_raw disks "$2" | while IFS='|' read -r letter label rpath; do
            _do_unmount "$2" "$letter"
        done
    else
        _do_unmount "$2" "$3"
    fi
    ;;
unmount-all)
    _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            _do_unmount "$name" "$dl"
        done
    done
    ;;
panic-unmount-all)
    # Last-resort cleanup for network loss — unblock Finder/apps quickly
    _log "panic-unmount: triggered"

    # Step 1: force-terminate all sshfs processes (SIGKILL)
    pkill -9 -f "sshfs" 2>/dev/null
    sleep 0.5

    # Step 2: force unmount every known mount point with timeout
    _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            mp="$(_mount_point "$name" "$dl")"
            [ -z "$mp" ] && continue
            _log "panic-unmount: $mp"
            # Force-unmount can hang on dead mounts → time-bounded
            _force_unmount_t "$mp"
            umount -f "$mp" 2>/dev/null
            # Clean up empty dir
            base_mp="$(_json_raw mount_base)"
            [ "$mp" != "$base_mp" ] && rmdir "$mp" 2>/dev/null
        done
    done

    # Step 3: catch any orphan mounts not in config (legacy paths like ~/mounts/*)
    base="$(_json_raw mount_base)"
    _list_fuse_mounts | while read -r orphan; do
        [ -z "$orphan" ] && continue
        _log "panic-unmount: orphan $orphan"
        _force_unmount_t "$orphan"
        umount -f "$orphan" 2>/dev/null
    done

    echo "panic-unmount:complete"
    ;;
panic-check)
    # Detect stale mounts (mount table says mounted, but ls hangs) and force-clean
    _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            mp="$(_mount_point "$name" "$dl")"
            [ -z "$mp" ] && continue
            if mount | grep -qF " on $mp "; then
                if ! _alive "$mp"; then
                    _log "panic-check: stale $mp — force unmounting"
                    _force_unmount_t "$mp"
                    umount -f "$mp" 2>/dev/null
                    # Verified per-PID SIGKILL — a broad `pkill -f "sshfs.*workstation"`
                    # pattern would also match unrelated AutoFuse mounts.
                    pgrep -f sshfs | while read -r _spid; do
                        echo " $(ps -p "$_spid" -o args= 2>/dev/null) " | grep -qF " $mp " && kill -9 "$_spid" 2>/dev/null
                    done
                    echo "healed:$mp"
                fi
            fi
        done
    done
    echo "panic-check:complete"
    ;;
learn-host-key)
    # Usage: learn-host-key <workstation>
    # Probes the best reachable endpoint and stores its SHA256 fingerprint
    # in config.json as host_key_sha256. Used for cross-network identity.
    [ -z "$2" ] && { echo "error:missing_workstation_name"; exit 1; }
    ws_name="$2"
    _read_workstation "$ws_name"
    if [ -z "$ws_lan_ip" ] && [ -z "$ws_vpn_ip" ] && [ "${#ws_additional_ips[@]}" -eq 0 ]; then
        echo "error:no_endpoints_configured"
        exit 1
    fi
    # Temporarily clear expected fingerprint so _pick_endpoint picks first reachable
    saved_expected="$ws_host_key_sha256"
    ws_host_key_sha256=""
    candidate=""
    for h in "$ws_lan_ip" "$ws_vpn_ip" "${ws_additional_ips[@]}" "${ws_name}.local"; do
        [ -z "$h" ] && continue
        _reachable "$h" 2>/dev/null && { candidate="$h"; break; }
    done
    if [ -z "$candidate" ]; then
        echo "error:no_reachable_endpoint"
        exit 1
    fi
    sha="$(_get_remote_host_key_sha256 "$candidate")"
    if [ -z "$sha" ]; then
        echo "error:keyscan_failed:${candidate}"
        exit 1
    fi
    # Write back to config.json atomically
    python3 - "$CONFIG" "$ws_name" "$sha" <<'PY'
import json, sys, os, tempfile, re
cfg_path, ws_name, sha = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg_path) as f:
    cfg = json.load(f)
for w in cfg.get('workstations', []):
    if w['name'] == ws_name:
        w['host_key_sha256'] = sha
        break
# Match Apple NSJSONWritingPrettyPrinted style — see _maybe_learn_host_key.
text = re.sub(r'^(\s*"[^"]+"):', r'\1 :', json.dumps(cfg, indent=2), flags=re.MULTILINE)
tmp = tempfile.NamedTemporaryFile('w', delete=False, dir=os.path.dirname(cfg_path))
tmp.write(text + '\n')
tmp.flush(); os.fsync(tmp.fileno()); tmp.close()
os.chmod(tmp.name, 0o600)
os.replace(tmp.name, cfg_path)
PY
    echo "learned:${ws_name}|${candidate}|${sha}"
    _log "learn-host-key: ${ws_name} → ${sha} via ${candidate}"
    ;;
verify-host-key)
    # Usage: verify-host-key <workstation>
    # Scans all endpoints and reports match/mismatch against stored fingerprint
    [ -z "$2" ] && { echo "error:missing_workstation_name"; exit 1; }
    ws_name="$2"
    _read_workstation "$ws_name"
    expected="$ws_host_key_sha256"
    if [ -z "$expected" ]; then
        echo "error:no_fingerprint_stored — run 'autofuse learn-host-key $ws_name' first"
        exit 1
    fi
    any_match=0
    for h in "$ws_lan_ip" "$ws_vpn_ip" "${ws_additional_ips[@]}" "${ws_name}.local"; do
        [ -z "$h" ] && continue
        if _reachable "$h" 2>/dev/null; then
            current="$(_get_remote_host_key_sha256 "$h")"
            if [ "$current" = "$expected" ]; then
                echo "match:${h}|${current}"
                any_match=1
            elif [ -n "$current" ]; then
                echo "mismatch:${h}|${current}|expected:${expected}"
            else
                echo "keyscan_failed:${h}"
            fi
        else
            echo "unreachable:${h}"
        fi
    done
    [ "$any_match" = "1" ] && exit 0 || exit 2
    ;;
pick-endpoint)
    # Usage: pick-endpoint <workstation>
    # Prints the best reachable endpoint (respects host key identity if set)
    [ -z "$2" ] && { echo "error:missing_workstation_name"; exit 1; }
    best="$(_pick_endpoint "$2")"
    if [ -n "$best" ]; then
        echo "$best"
    else
        echo "error:no_matching_endpoint"
        exit 1
    fi
    ;;
endpoint-cache-show)
    # Usage: endpoint-cache-show [workstation]
    # Dump the smart-endpoint cache so users can see why `_pick_endpoint`
    # returned what it did. One line per entry: ws|endpoint|rtt_ms|age_sec.
    if [ ! -d "$AF_ENDPOINT_CACHE_DIR" ]; then
        echo "empty"
        exit 0
    fi
    _ws_filter="${2:-}"
    _now_ts="$(date +%s)"
    for _f in "$AF_ENDPOINT_CACHE_DIR"/*; do
        [ -f "$_f" ] || continue
        _ws_name="$(basename "$_f")"
        [ -n "$_ws_filter" ] && [ "$_ws_name" != "$_ws_filter" ] && continue
        _line="$(cat "$_f" 2>/dev/null)"
        IFS=$'\t' read -r _ep _rtt _ts <<< "$_line"
        [[ "$_ts" =~ ^[0-9]+$ ]] || _ts="$_now_ts"
        _age=$((_now_ts - _ts))
        echo "${_ws_name}|${_ep}|${_rtt:-0}|${_age}"
    done
    ;;
endpoint-cache-clear)
    # Usage: endpoint-cache-clear [workstation]
    # Remove cached endpoints so the next _pick_endpoint does a full
    # iteration. Useful after a network switch when you suspect the
    # cached IP no longer reflects reality.
    if [ -n "$2" ]; then
        _f="$(_endpoint_cache_file "$2")"
        rm -f "$_f" 2>/dev/null
        _log "endpoint-cache-clear: $2"
        echo "cleared:$2"
    else
        rm -rf "$AF_ENDPOINT_CACHE_DIR" 2>/dev/null
        _log "endpoint-cache-clear: all"
        echo "cleared:all"
    fi
    ;;
wol)
    _do_wol "$2"
    ;;
wol-wait)
    _wol_and_wait "$2" "${3:-60}"
    ;;
heal)
    if [ -z "$3" ]; then
        _json_raw disks "$2" | while IFS='|' read -r letter label rpath; do
            _do_heal "$2" "$letter"
        done
    else
        _do_heal "$2" "$3"
    fi
    ;;
heal-all)
    _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
        IFS=',' read -ra disk_arr <<< "$disks"
        for dl in "${disk_arr[@]}"; do
            _do_heal "$name" "$dl"
        done
    done
    ;;
ping-check)
    if [ -n "$2" ]; then
        _do_ping "$2"
    else
        _json_raw list_workstations | while IFS='|' read -r name lip vip disks mac; do
            _do_ping "$name"
        done
    fi
    ;;
diagnose)
    [ -z "$2" ] && { echo "error:missing_workstation_name"; exit 1; }
    _do_diagnose "$2"
    ;;
check-deps)
    _check_sshfs
    ;;
keychain-add)
    [ -z "$2" ] && { echo "error:missing_workstation_name"; exit 1; }
    _read_workstation "$2"
    if [ -z "$ws_ssh_key" ]; then
        echo "error:no_ssh_key_configured:$2"
        exit 1
    fi
    _keychain_add "$ws_ssh_key"
    ;;
log)
    if [ -f "$AF_LOG" ]; then
        tail -50 "$AF_LOG"
    else
        echo "No log file found."
    fi
    ;;
log-clear)
    rm -f "$AF_LOG" "${AF_LOG}.old"
    _log "log cleared"
    echo "ok:log_cleared"
    ;;
health)
    _do_health_all
    ;;
health-json)
    _do_health_json
    ;;
export-config)
    _do_export_config "$2"
    ;;
import-config)
    [ -z "$2" ] && { echo "error:missing_file_path"; exit 1; }
    _do_import_config "$2" "no"
    ;;
*)
    echo "AutoFuse v4"
    echo "Usage: $0 <command> [workstation] [disk]"
    echo ""
    echo "Commands:"
    echo "  list                    List configured workstations"
    echo "  disks <ws>              List disks for workstation"
    echo "  status <ws> <disk>      Check mount status"
    echo "  status-all              Check all mounts"
    echo "  mount <ws> [disk]       Mount disk(s)"
    echo "  mount-all               Mount all disks"
    echo "  unmount <ws> [disk]     Unmount disk(s)"
    echo "  unmount-all             Unmount all"
    echo "  wol <ws>                Send Wake-on-LAN"
    echo "  wol-wait <ws> [secs]    WoL + wait for online (default 60s)"
    echo "  learn-host-key <ws>     Record SSH host key fingerprint for cross-network identity"
    echo "  verify-host-key <ws>    Verify stored fingerprint against each endpoint"
    echo "  pick-endpoint <ws>      Print the best reachable endpoint (key-verified if set)"
    echo "  endpoint-cache-show [ws]    Show last-working endpoint cache"
    echo "  endpoint-cache-clear [ws]   Invalidate endpoint cache (all or one ws)"
    echo "  heal <ws> [disk]        Auto-recover stale mounts"
    echo "  heal-all                Heal all stale mounts"
    echo "  ping-check [ws]         Check host reachability"
    echo "  diagnose <ws>           Full diagnostic report: endpoints + ports + host-key + mounts"
    echo "  check-deps              Check if sshfs/macFUSE are installed"
    echo "  keychain-add <ws>       Add workstation SSH key to macOS keychain"
    echo "  health                  Show health dashboard for all mounts"
    echo "  health-json             Health dashboard as JSON (for GUI)"
    echo "  export-config [ws]      Export config for team sharing (no secrets)"
    echo "  import-config <file>    Import workstations from shared config"
    echo "  log                     Show last 50 log entries"
    echo "  log-clear               Clear the log file"
    exit 1
    ;;
esac
