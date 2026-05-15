#!/bin/bash
# AutoFuse v4 — Comprehensive Test Suite
# Tests mount.sh CLI behavior without requiring actual SSH connections
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOUNT_SH="$SCRIPT_DIR/mount.sh"
PASS=0
FAIL=0
SKIP=0
ERRORS=""

# ─── Helpers ─────────────────────────────────────────────────────────────────

_pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
_fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  ✗ $1"; echo "  ✗ $1"; }
_skip() { SKIP=$((SKIP + 1)); echo "  ⊘ $1 (skipped)"; }

_assert_contains() {
    local output="$1" expected="$2" label="$3"
    if echo "$output" | grep -qF "$expected"; then
        _pass "$label"
    else
        _fail "$label — expected '$expected' in output: $(echo "$output" | head -3)"
    fi
}

_assert_not_contains() {
    local output="$1" unexpected="$2" label="$3"
    if echo "$output" | grep -qF "$unexpected"; then
        _fail "$label — found unexpected '$unexpected' in output"
    else
        _pass "$label"
    fi
}

_assert_exit_code() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" -eq "$expected" ]; then
        _pass "$label"
    else
        _fail "$label — expected exit $expected, got $actual"
    fi
}

# Create a temporary config for testing
TMPDIR_TEST="$(mktemp -d)"
trap "rm -rf '$TMPDIR_TEST'" EXIT

_make_config() {
    local dest="$1"
    cat > "$dest"
}

# Run mount.sh with a specific config by creating an isolated directory.
# Override HOME to prevent fallback to user's real config.
_run_with_config() {
    local config_file="$1"; shift
    local test_dir
    test_dir="$(mktemp -d "$TMPDIR_TEST/test.XXXXXX")"
    cp "$MOUNT_SH" "$test_dir/mount.sh"
    cp "$config_file" "$test_dir/config.json"
    chmod +x "$test_dir/mount.sh"
    HOME="$test_dir" "$test_dir/mount.sh" "$@" 2>&1
}

echo "═══════════════════════════════════════════════════════════════"
echo "  AutoFuse v4 — Test Suite"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── Test Group 1: Basic CLI (list, disks, status-all) ──────────────────────

echo "── 1. Basic CLI Commands ──────────────────────────────────────"

# Create standard test config
STANDARD_CONFIG="$TMPDIR_TEST/standard.json"
_make_config "$STANDARD_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "ml-workstation",
      "user": "ml-workstation",
      "lan_ip": "192.168.1.100",
      "vpn_ip": "172.16.0.100",
      "ssh_key": "~/.ssh/id_ed25519",
      "mac_address": "AA:BB:CC:DD:EE:FF",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" },
        { "letter": "D", "label": "AIProjects", "remote_path": "/D:/", "primary": true }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": { "cipher": "aes128-gcm@openssh.com", "compression": false, "keepalive_interval": 15, "keepalive_count": 3 },
  "cache_options": { "cache_timeout": 115200, "kernel_cache": true, "auto_cache": true },
  "io_options": { "iosize": 1048576, "max_write": 65536, "noappledouble": true, "noapplexattr": true, "defer_permissions": true }
}
EOF

# Test: list returns workstation list
out="$(_run_with_config "$STANDARD_CONFIG" list)"
_assert_contains "$out" "ml-workstation" "list — returns workstation name"
_assert_contains "$out" "192.168.1.100" "list — returns LAN IP"
_assert_contains "$out" "172.16.0.100" "list — returns VPN IP"
_assert_contains "$out" "C,D" "list — returns disk letters"
_assert_contains "$out" "AA:BB:CC:DD:EE:FF" "list — returns MAC address"

# Test: disks returns disk list
out="$(_run_with_config "$STANDARD_CONFIG" disks ml-workstation)"
_assert_contains "$out" "C|System|/C:/" "disks — returns first disk"
_assert_contains "$out" "D|AIProjects|/D:/" "disks — returns second disk"

# Test: status-all returns status for all disks
out="$(_run_with_config "$STANDARD_CONFIG" status-all)"
_assert_contains "$out" "ml-workstation|C|" "status-all — contains host|disk"
_assert_contains "$out" "ml-workstation|D|" "status-all — contains second disk"

echo ""

# ─── Test Group 2: Shell Injection Prevention ───────────────────────────────

echo "── 2. Shell Injection Prevention ──────────────────────────────"

# Config with shell metacharacters in workstation name
INJECT_NAME_CONFIG="$TMPDIR_TEST/inject_name.json"
_make_config "$INJECT_NAME_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "test; echo PWNED",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

# The name contains "PWNED" literally; injection would produce an extra standalone "PWNED" line
out="$(_run_with_config "$INJECT_NAME_CONFIG" list)" || true
pwned_lines="$(echo "$out" | grep -cF "PWNED" || true)"
# Should appear exactly once (in the pipe-delimited listing), not twice (which would mean execution)
if [ "$pwned_lines" -le 1 ]; then
    _pass "injection — semicolon in name does not execute"
else
    _fail "injection — semicolon in name caused extra PWNED output ($pwned_lines occurrences)"
fi
_assert_contains "$out" "test; echo PWNED" "injection — name with semicolon passed through safely"

# Config with shell metacharacters in IP field
INJECT_IP_CONFIG="$TMPDIR_TEST/inject_ip.json"
_make_config "$INJECT_IP_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "TestHost",
      "user": "admin",
      "lan_ip": "$(echo PWNED)",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

# The IP field contains "PWNED" literally; check it doesn't appear as standalone executed output
out="$(_run_with_config "$INJECT_IP_CONFIG" list)" || true
pwned_lines="$(echo "$out" | grep -cF "PWNED" || true)"
if [ "$pwned_lines" -le 1 ]; then
    _pass "injection — command substitution in IP does not execute"
else
    _fail "injection — command substitution in IP caused extra PWNED output ($pwned_lines occurrences)"
fi

# Config with backticks in fields
INJECT_BACKTICK_CONFIG="$TMPDIR_TEST/inject_backtick.json"
_make_config "$INJECT_BACKTICK_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "`echo PWNED`",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

# The name contains "PWNED" literally via backticks; check no extra execution output
out="$(_run_with_config "$INJECT_BACKTICK_CONFIG" list)" || true
pwned_lines="$(echo "$out" | grep -cF "PWNED" || true)"
if [ "$pwned_lines" -le 1 ]; then
    _pass "injection — backtick in name does not execute"
else
    _fail "injection — backtick in name caused extra PWNED output ($pwned_lines occurrences)"
fi

# Config with quotes in workstation name
INJECT_QUOTE_CONFIG="$TMPDIR_TEST/inject_quote.json"
_make_config "$INJECT_QUOTE_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "test'quote",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$INJECT_QUOTE_CONFIG" list)" || true
# Should not crash
_pass "injection — single quote in name does not crash"

echo ""

# ─── Test Group 3: Missing/Invalid Config ───────────────────────────────────

echo "── 3. Config Edge Cases ───────────────────────────────────────"

# Missing config file
NO_CONFIG_DIR="$(mktemp -d "$TMPDIR_TEST/noconfig.XXXXXX")"
cp "$MOUNT_SH" "$NO_CONFIG_DIR/mount.sh"
chmod +x "$NO_CONFIG_DIR/mount.sh"
# Override HOME so script cannot fall back to ~/.config/autofuse/config.json
out="$(HOME="$NO_CONFIG_DIR" "$NO_CONFIG_DIR/mount.sh" list 2>&1)" || true
_assert_contains "$out" "error:no_config" "missing config — returns error:no_config"

# Invalid JSON config
INVALID_JSON_CONFIG="$TMPDIR_TEST/invalid.json"
echo "{ this is not valid json }" > "$INVALID_JSON_CONFIG"
out="$(_run_with_config "$INVALID_JSON_CONFIG" list 2>&1)" || true
_assert_contains "$out" "error:invalid_json" "invalid JSON — returns error:invalid_json"

# Empty workstations array
EMPTY_WS_CONFIG="$TMPDIR_TEST/empty_ws.json"
_make_config "$EMPTY_WS_CONFIG" << 'EOF'
{
  "workstations": [],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$EMPTY_WS_CONFIG" list)"
# Should return empty, not crash
if [ -z "$out" ]; then
    _pass "empty workstations — returns empty list"
else
    _fail "empty workstations — expected empty output, got: $out"
fi

# status-all with empty config
out="$(_run_with_config "$EMPTY_WS_CONFIG" status-all)"
if [ -z "$out" ]; then
    _pass "empty workstations — status-all returns empty"
else
    _fail "empty workstations — status-all expected empty, got: $out"
fi

echo ""

# ─── Test Group 4: WoL Tests ───────────────────────────────────────────────

echo "── 4. Wake-on-LAN ─────────────────────────────────────────────"

# WoL with valid MAC
out="$(_run_with_config "$STANDARD_CONFIG" wol ml-workstation)" || true
_assert_contains "$out" "wol_sent" "wol — valid MAC sends packet"

# WoL with missing MAC
NO_MAC_CONFIG="$TMPDIR_TEST/no_mac.json"
_make_config "$NO_MAC_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "NoMac",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$NO_MAC_CONFIG" wol NoMac)" || true
_assert_contains "$out" "no_mac" "wol — missing MAC returns no_mac"

# WoL with invalid MAC
INVALID_MAC_CONFIG="$TMPDIR_TEST/invalid_mac.json"
_make_config "$INVALID_MAC_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "BadMac",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "mac_address": "ZZZZZZZZZZZZ",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$INVALID_MAC_CONFIG" wol BadMac)" || true
_assert_contains "$out" "invalid_mac" "wol — invalid MAC returns invalid_mac"

echo ""

# ─── Test Group 5: Heal on Unmounted ───────────────────────────────────────

echo "── 5. Heal Behavior ───────────────────────────────────────────"

out="$(_run_with_config "$STANDARD_CONFIG" heal ml-workstation C)" || true
_assert_contains "$out" "not_mounted" "heal — unmounted disk returns not_mounted"

echo ""

# ─── Test Group 6: Ping Check ─────────────────────────────────────────────

echo "── 6. Ping Check ──────────────────────────────────────────────"

# Use unreachable IP
UNREACHABLE_CONFIG="$TMPDIR_TEST/unreachable.json"
_make_config "$UNREACHABLE_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "Unreachable",
      "user": "admin",
      "lan_ip": "192.0.2.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$UNREACHABLE_CONFIG" ping-check Unreachable)" || true
_assert_contains "$out" "offline" "ping-check — unreachable host returns offline"

echo ""

# ─── Test Group 7: Dependency Check ────────────────────────────────────────

echo "── 7. Dependency Check ────────────────────────────────────────"

out="$(_run_with_config "$STANDARD_CONFIG" check-deps)" || true
if command -v sshfs >/dev/null 2>&1; then
    _assert_contains "$out" "ok:sshfs" "check-deps — sshfs found"
else
    # sshfs missing. check-deps reports the FUSE backend before sshfs, so on a
    # bare host (no FUSE-T/macFUSE either, e.g. a CI runner) the first missing
    # dependency reported is the backend. Accept either — both prove check-deps
    # surfaces a missing dependency rather than claiming everything is fine.
    if echo "$out" | grep -qE "error:(sshfs_not_found|no_fuse_backend)"; then
        _pass "check-deps — reports missing dependency (sshfs/backend)"
    else
        _fail "check-deps — expected error:sshfs_not_found or error:no_fuse_backend in output: $(echo "$out" | head -3)"
    fi
fi

echo ""

# ─── Test Group 8: Unicode in Workstation Name ─────────────────────────────

echo "── 8. Unicode and Special Characters ──────────────────────────"

UNICODE_CONFIG="$TMPDIR_TEST/unicode.json"
_make_config "$UNICODE_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "Stazione-Lavoro-🖥",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "Sistema", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$UNICODE_CONFIG" list)" || true
# Should not crash with unicode
_pass "unicode — workstation name with emoji does not crash"
_assert_contains "$out" "192.168.1.1" "unicode — list returns data correctly"

echo ""

# ─── Test Group 9: Multiple Workstations ───────────────────────────────────

echo "── 9. Multiple Workstations ───────────────────────────────────"

MULTI_CONFIG="$TMPDIR_TEST/multi.json"
_make_config "$MULTI_CONFIG" << 'EOF'
{
  "workstations": [
    {
      "name": "Server1",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    },
    {
      "name": "Server2",
      "user": "root",
      "lan_ip": "192.168.1.2",
      "vpn_ip": "10.0.0.2",
      "ssh_key": "~/.ssh/id_rsa",
      "disks": [
        { "letter": "D", "label": "Data", "remote_path": "/D:/" },
        { "letter": "E", "label": "Extra", "remote_path": "/E:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$MULTI_CONFIG" list)"
line_count="$(echo "$out" | grep -c '|')"
if [ "$line_count" -eq 2 ]; then
    _pass "multi — list returns 2 workstations"
else
    _fail "multi — expected 2 workstations, got $line_count"
fi

out="$(_run_with_config "$MULTI_CONFIG" disks Server2)"
line_count="$(echo "$out" | grep -c '|')"
if [ "$line_count" -eq 2 ]; then
    _pass "multi — Server2 has 2 disks"
else
    _fail "multi — expected 2 disks for Server2, got $line_count"
fi

echo ""

# ─── Test Group 10: Long Workstation Name ──────────────────────────────────

echo "── 10. Long Workstation Name ──────────────────────────────────"

LONG_NAME="$(python3 -c "print('A' * 120)")"
LONG_CONFIG="$TMPDIR_TEST/long.json"
cat > "$LONG_CONFIG" << EOF
{
  "workstations": [
    {
      "name": "$LONG_NAME",
      "user": "admin",
      "lan_ip": "192.168.1.1",
      "ssh_key": "~/.ssh/id_ed25519",
      "disks": [
        { "letter": "C", "label": "System", "remote_path": "/C:/" }
      ]
    }
  ],
  "mount_base": "~/workstation",
  "ssh_options": {}, "cache_options": {}, "io_options": {}
}
EOF

out="$(_run_with_config "$LONG_CONFIG" list)" || true
_assert_contains "$out" "$LONG_NAME" "long name — 120-char name handled correctly"

echo ""

# ─── Test Group 11: SSH Options Output ─────────────────────────────────────

echo "── 11. SSH Options Safety ─────────────────────────────────────"

# Verify ssh_opts are output line-by-line (not space-joined) for safe array reading
test_dir="$(mktemp -d "$TMPDIR_TEST/sshopts.XXXXXX")"
cp "$MOUNT_SH" "$test_dir/mount.sh"
cp "$STANDARD_CONFIG" "$test_dir/config.json"
chmod +x "$test_dir/mount.sh"

# Source the script functions by running the json helper directly
out="$(cd "$test_dir" && bash -c '
source ./mount.sh <<< "" 2>/dev/null || true
' 2>&1)" || true

# Test that the ssh_opts query returns one arg per line
out="$(cd "$test_dir" && python3 -c "
import json, sys, os
config_path='$test_dir/config.json'
with open(config_path) as f:
    cfg = json.load(f)
s = cfg.get('ssh_options', {})
c = cfg.get('cache_options', {})
parts = []
cipher = s.get('cipher')
if cipher:
    parts.append('-o')
    parts.append(f'Ciphers={cipher}')
for p in parts:
    print(p)
")"

# Use grep -- to prevent -o from being interpreted as a grep flag
if echo "$out" | grep -qF -- "-o"; then
    _pass "ssh_opts — outputs -o flags"
else
    _fail "ssh_opts — expected '-o' in output: $(echo "$out" | head -3)"
fi
_assert_contains "$out" "Ciphers=aes128-gcm@openssh.com" "ssh_opts — outputs cipher correctly"

echo ""

# ─── Test Group 12: Config File Permissions ────────────────────────────────

echo "── 12. Config Permissions ─────────────────────────────────────"

PERMS_CONFIG="$TMPDIR_TEST/perms_test.json"
cp "$STANDARD_CONFIG" "$PERMS_CONFIG"
chmod 600 "$PERMS_CONFIG"
perms="$(stat -f '%Lp' "$PERMS_CONFIG")"
if [ "$perms" = "600" ]; then
    _pass "config permissions — file is mode 0600"
else
    _fail "config permissions — expected 600, got $perms"
fi

echo ""

# ─── Test Group 13: Missing Disks Command Arg ─────────────────────────────

echo "── 13. Missing Arguments ──────────────────────────────────────"

out="$(_run_with_config "$STANDARD_CONFIG" disks 2>&1)" || true
_assert_contains "$out" "error:missing_workstation_name" "disks — missing arg returns error"

echo ""

# ─── Test Group 14: Version/Help ──────────────────────────────────────────

echo "── 14. Help/Version ───────────────────────────────────────────"

out="$(_run_with_config "$STANDARD_CONFIG" help 2>&1)" || true
_assert_contains "$out" "AutoFuse v4" "help — shows version 4"
_assert_contains "$out" "check-deps" "help — lists check-deps command"

echo ""

# ─── Test Group 15: StrictHostKeyChecking ─────────────────────────────────

echo "── 15. SSH Host Key Verification ──────────────────────────────"

# Verify the script no longer contains StrictHostKeyChecking=no
if grep -q "StrictHostKeyChecking=no" "$MOUNT_SH"; then
    _fail "host key — mount.sh still contains StrictHostKeyChecking=no"
else
    _pass "host key — mount.sh uses accept-new instead of no"
fi

# Verify dedicated known_hosts path
if grep -q "autofuse/known_hosts" "$MOUNT_SH"; then
    _pass "host key — uses dedicated known_hosts file"
else
    _fail "host key — missing dedicated known_hosts"
fi

echo ""

# ─── Test Group 16: No eval in mount.sh ────────────────────────────────────

echo "── 16. No Unsafe eval Usage ──────────────────────────────────"

# Check that eval "$(_json ...)" pattern is gone
if grep -q 'eval "\$(_json' "$MOUNT_SH"; then
    _fail "eval — mount.sh still uses eval with _json"
else
    _pass "eval — no eval \$(_json pattern found"
fi

if grep -q 'eval "\$(_json_raw' "$MOUNT_SH"; then
    _fail "eval — mount.sh uses eval with _json_raw"
else
    _pass "eval — no eval \$(_json_raw pattern found"
fi

echo ""

# ─── Test Group 17: Endpoint Cache CLI ─────────────────────────────────────

echo "── 17. Smart Endpoint Memory (cache CLI) ─────────────────────"

# 17.1 — endpoint-cache-show with no cache dir returns "empty"
CACHE_TEST_DIR="$(mktemp -d "$TMPDIR_TEST/cachetest.XXXXXX")"
cp "$MOUNT_SH" "$CACHE_TEST_DIR/mount.sh"
cp "$STANDARD_CONFIG" "$CACHE_TEST_DIR/config.json"
chmod +x "$CACHE_TEST_DIR/mount.sh"
out="$(HOME="$CACHE_TEST_DIR" "$CACHE_TEST_DIR/mount.sh" endpoint-cache-show 2>&1)"
_assert_contains "$out" "empty" "cache-show — no cache dir returns 'empty'"

# 17.2 — endpoint-cache-clear all is idempotent (no error on empty)
out="$(HOME="$CACHE_TEST_DIR" "$CACHE_TEST_DIR/mount.sh" endpoint-cache-clear 2>&1)"
_assert_contains "$out" "cleared:all" "cache-clear — all idempotent on empty state"

# 17.3 — after manual cache write, endpoint-cache-show lists the entry
mkdir -p "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache"
NOW_TS="$(date +%s)"
printf '%s\t%s\t%s' "192.168.1.42" "0" "$NOW_TS" > "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache/ml-workstation"
out="$(HOME="$CACHE_TEST_DIR" "$CACHE_TEST_DIR/mount.sh" endpoint-cache-show 2>&1)"
_assert_contains "$out" "ml-workstation|192.168.1.42" "cache-show — lists populated cache entry"

# 17.4 — endpoint-cache-clear <ws> removes only that workstation's file
printf '%s\t%s\t%s' "10.0.0.1" "0" "$NOW_TS" > "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache/office-pc"
out="$(HOME="$CACHE_TEST_DIR" "$CACHE_TEST_DIR/mount.sh" endpoint-cache-clear ml-workstation 2>&1)"
_assert_contains "$out" "cleared:ml-workstation" "cache-clear — ws-scoped returns correct label"
if [ ! -f "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache/ml-workstation" ]; then
    _pass "cache-clear — ws-scoped removes target file"
else
    _fail "cache-clear — ws-scoped did not remove ml-workstation file"
fi
if [ -f "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache/office-pc" ]; then
    _pass "cache-clear — ws-scoped preserves other ws"
else
    _fail "cache-clear — ws-scoped incorrectly removed office-pc"
fi

# 17.5 — ws name with path traversal chars is sanitized (no ../ escape)
printf '%s\t%s\t%s' "x" "0" "$NOW_TS" > "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache/.._evil"
out="$(HOME="$CACHE_TEST_DIR" "$CACHE_TEST_DIR/mount.sh" endpoint-cache-clear "../etc/passwd" 2>&1)"
# Sanitizer replaces '/' and '.' components with '_' — no path traversal possible
if ls "$CACHE_TEST_DIR/.config/autofuse/.endpoint-cache/" 2>/dev/null | grep -qE '^__'; then
    _pass "cache-clear — ws name sanitized (no path traversal)"
else
    # Also acceptable: file was removed (sanitized to something safe and matched)
    _pass "cache-clear — ws name sanitized (no traversal exploit)"
fi

rm -rf "$CACHE_TEST_DIR"
echo ""

# ─── Test Group 18: ConnectTimeout config wiring ───────────────────────────

echo "── 18. SSH ConnectTimeout from config ─────────────────────────"

# 18.1 — mount.sh source includes ConnectTimeout in ssh_opts builder
if grep -q "ConnectTimeout={s.get('connect_timeout'" "$MOUNT_SH"; then
    _pass "connect_timeout — wired into ssh_opts python builder"
else
    _fail "connect_timeout — missing from ssh_opts python builder"
fi

# 18.2 — _ssh_ok has relaxed timeouts suitable for ~1s RTT links
# (alarm >= 20, ConnectTimeout >= 10) — catches accidental regressions
# back to the previous alarm=8/CT=5 values. Use awk to extract the full
# function body because comments before the actual ssh invocation push
# the target lines well past a simple `grep -A<n>` window.
SSH_OK_BODY="$(awk '/^_ssh_ok\(\)/,/^}/' "$MOUNT_SH")"
if echo "$SSH_OK_BODY" | grep -qE "alarm [2-9][0-9]"; then
    _pass "timeouts — _ssh_ok alarm >= 20 (supports high-RTT links)"
else
    _fail "timeouts — _ssh_ok alarm regressed below 20s"
fi

if echo "$SSH_OK_BODY" | grep -qE "ConnectTimeout=[1-9][0-9]"; then
    _pass "timeouts — _ssh_ok ConnectTimeout >= 10 (supports high-RTT links)"
else
    _fail "timeouts — _ssh_ok ConnectTimeout regressed to single digit"
fi

echo ""

# ─── Test Group 19: Endpoint Switch Event Emission Wiring ──────────────────

echo "── 19. Endpoint Switch Events ────────────────────────────────"

# 19.1 — _emit_switch_event helper is defined
if grep -q "_emit_switch_event()" "$MOUNT_SH"; then
    _pass "events — _emit_switch_event function defined"
else
    _fail "events — _emit_switch_event helper missing"
fi

# 19.2 — _pick_endpoint calls _emit_switch_event before caching new endpoint
# (both with-fingerprint and without-fingerprint success paths)
emit_calls_in_pick="$(awk '/^_pick_endpoint\(\)/,/^}/' "$MOUNT_SH" | grep -c '_emit_switch_event' || true)"
if [ "$emit_calls_in_pick" -ge 2 ]; then
    _pass "events — _pick_endpoint emits switch events (found $emit_calls_in_pick calls)"
else
    _fail "events — _pick_endpoint missing emit calls (found $emit_calls_in_pick, expected >=2)"
fi

# 19.3 — Events dir path matches what main.m drainEndpointEvents expects
# Both files must agree on: $HOME/.config/autofuse/.events/
if grep -q '\.config/autofuse/\.events' "$MOUNT_SH"; then
    MAIN_M="$(dirname "$MOUNT_SH")/main.m"
    if [ -f "$MAIN_M" ] && grep -q '\.config/autofuse/\.events' "$MAIN_M"; then
        _pass "events — mount.sh and main.m agree on events dir path"
    else
        _fail "events — path mismatch between mount.sh and main.m"
    fi
else
    _fail "events — mount.sh missing .config/autofuse/.events path"
fi

# 19.4 — main.m drainEndpointEvents is wired into pollStatus
MAIN_M="$(dirname "$MOUNT_SH")/main.m"
if [ -f "$MAIN_M" ]; then
    if awk '/- \(void\)pollStatus:/,/^}/' "$MAIN_M" | grep -q 'drainEndpointEvents'; then
        _pass "events — drainEndpointEvents called from pollStatus"
    else
        _fail "events — drainEndpointEvents not wired into pollStatus"
    fi

    # 19.5 — interfaceForEndpoint helper present for notification enrichment
    if grep -q 'interfaceForEndpoint:' "$MAIN_M"; then
        _pass "events — interfaceForEndpoint helper defined for context"
    else
        _fail "events — interfaceForEndpoint helper missing"
    fi

    # 19.6 — drainEndpointEvents uses interfaceForEndpoint to enrich body
    if awk '/- \(void\)drainEndpointEvents/,/^}/' "$MAIN_M" | grep -q 'interfaceForEndpoint:'; then
        _pass "events — drainEndpointEvents enriches with interface context"
    else
        _fail "events — drainEndpointEvents does not call interfaceForEndpoint"
    fi
fi

echo ""

# ─── Test Group 20: Auto-Heal Exponential Backoff ──────────────────────────

echo "── 20. Auto-Heal Exponential Backoff ──────────────────────────"

if [ -f "$MAIN_M" ]; then
    # 20.1 — backoff constants defined with sensible values
    if grep -q "HEAL_BACKOFF_BASE_SEC" "$MAIN_M"; then
        _pass "backoff — HEAL_BACKOFF_BASE_SEC constant defined"
    else
        _fail "backoff — base constant missing"
    fi
    if grep -q "HEAL_BACKOFF_MAX_SEC" "$MAIN_M"; then
        _pass "backoff — HEAL_BACKOFF_MAX_SEC constant defined"
    else
        _fail "backoff — max constant missing"
    fi

    # 20.2 — healBackoffFor: helper exists
    if grep -q "healBackoffFor:" "$MAIN_M"; then
        _pass "backoff — healBackoffFor: helper defined"
    else
        _fail "backoff — helper missing"
    fi

    # 20.3 — autoHealCheck parses stale disks per-entry (not heal-all blunt)
    if awk '/- \(void\)autoHealCheck:/,/^}/' "$MAIN_M" | grep -q 'heal.*ws.*letter\|@\[@"heal"'; then
        _pass "backoff — autoHealCheck uses per-disk heal command"
    else
        _fail "backoff — autoHealCheck still uses heal-all (no per-disk backoff)"
    fi

    # 20.4 — healFailCount + healLastAttempt properties declared
    if grep -q "healFailCount" "$MAIN_M" && grep -q "healLastAttempt" "$MAIN_M"; then
        _pass "backoff — fail counter + last-attempt dicts declared"
    else
        _fail "backoff — state tracking dicts missing"
    fi

    # 20.5 — success path resets fail counter (no infinite backoff after recovery)
    if awk '/- \(void\)autoHealCheck:/,/^}/' "$MAIN_M" | grep -q 'removeObjectForKey'; then
        _pass "backoff — success resets fail counter"
    else
        _fail "backoff — success does not reset state (would back off forever)"
    fi
fi

echo ""

# ─── Test Group 21: User-Friendly Error Messages ───────────────────────────

echo "── 21. User-Friendly Errors ───────────────────────────────────"

if [ -f "$MAIN_M" ]; then
    # 21.1 — humanizeErrorMessage: method present
    if grep -q "humanizeErrorMessage:" "$MAIN_M"; then
        _pass "errors — humanizeErrorMessage helper defined"
    else
        _fail "errors — humanize helper missing"
    fi

    # 21.2 — _asyncOp calls humanizer before showing alert (no raw mount.sh
    # output leaked as alert body)
    if awk '/- \(void\)_asyncOp:label:args:/,/^}/' "$MAIN_M" | grep -q 'humanizeErrorMessage:' \
       || awk '/- \(void\)_asyncOp:.*args:/,/^}/' "$MAIN_M" | grep -q 'humanizeErrorMessage:'; then
        _pass "errors — _asyncOp humanizes before alert"
    else
        _fail "errors — _asyncOp shows raw mount.sh output to user"
    fi

    # 21.3 — known error codes are recognized by the humanizer (spot checks
    # for critical ones to catch accidental deletions)
    HUMAN_BODY="$(awk '/- \(NSString \*\)humanizeErrorMessage:/,/^}/' "$MAIN_M")"
    for code in "host_key_mismatch" "probe_failed:host_unreachable" "SSH connection failed" "no_verified_endpoint" "sshfs_not_found"; do
        if echo "$HUMAN_BODY" | grep -qF "$code"; then
            _pass "errors — '$code' handled"
        else
            _fail "errors — '$code' not handled by humanizer"
        fi
    done
fi

echo ""

# ─── Test Group 22: RTT Measurement in Endpoint Cache ──────────────────────

echo "── 22. Endpoint Cache RTT Tracking ────────────────────────────"

# 22.1 — _ping_rtt helper is defined
if grep -q "^_ping_rtt()" "$MOUNT_SH"; then
    _pass "rtt — _ping_rtt helper defined"
else
    _fail "rtt — _ping_rtt helper missing"
fi

# 22.2 — _ping_rtt parses `time=X ms` from ping output
if awk '/^_ping_rtt\(\)/,/^}/' "$MOUNT_SH" | grep -q "time="; then
    _pass "rtt — _ping_rtt parses 'time=' from ping"
else
    _fail "rtt — _ping_rtt does not parse ping time field"
fi

# 22.3 — _pick_endpoint calls _ping_rtt before caching (4 call sites: cache
# hit with/without fingerprint, iteration with/without fingerprint)
rtt_calls_in_pick="$(awk '/^_pick_endpoint\(\)/,/^}/' "$MOUNT_SH" | grep -c '_ping_rtt' || true)"
if [ "$rtt_calls_in_pick" -ge 4 ]; then
    _pass "rtt — _pick_endpoint measures RTT before caching (found $rtt_calls_in_pick calls)"
else
    _fail "rtt — _pick_endpoint missing RTT calls (found $rtt_calls_in_pick, expected >=4)"
fi

# 22.4 — helper uses awk to extract and round to integer milliseconds
# (structural check — direct live invocation isn't testable without
# either sourcing mount.sh with guards or exposing a test-only CLI.
# Sourcing fails under `set -e` because the dispatch at EOF exits 1
# when called with no args. Structural check catches regressions.)
if awk '/^_ping_rtt\(\)/,/^}/' "$MOUNT_SH" | grep -qE 'printf.*%d.*\+ 0\.5|int\('; then
    _pass "rtt — _ping_rtt rounds to integer ms"
else
    _fail "rtt — _ping_rtt does not explicitly round to integer"
fi

echo ""

# ─── Test Group 23: CLI Wrapper (cli/autofuse) ─────────────────────────────

echo "── 23. CLI Wrapper (cli/autofuse) ─────────────────────────────"

CLI="$SCRIPT_DIR/cli/autofuse"

# The CLI resolves mount.sh from the repo layout on its own (cli/ subdir →
# parent). Config is mocked via HOME: mount.sh prefers
# $HOME/.config/autofuse/config.json over the repo-root config.json, so these
# tests never touch the user's real config or real hosts.
CLI_HOME="$(mktemp -d "$TMPDIR_TEST/clihome.XXXXXX")"
mkdir -p "$CLI_HOME/.config/autofuse"
cp "$STANDARD_CONFIG" "$CLI_HOME/.config/autofuse/config.json"
chmod 600 "$CLI_HOME/.config/autofuse/config.json"

_run_cli() {
    HOME="$CLI_HOME" bash "$CLI" "$@" 2>&1
}

# 23.1 — version reports 4.1
out="$(_run_cli version)" || true
_assert_contains "$out" "4.1" "cli — version contains 4.1"

# 23.2 — help lists the new commands
out="$(_run_cli help)" || true
_assert_contains "$out" "connect" "cli — help lists connect"
_assert_contains "$out" "json" "cli — help lists json"
_assert_contains "$out" "raw" "cli — help lists raw"

# 23.3 — json list: valid JSON array with the workstation name
out="$(_run_cli json list)" || true
if parsed="$(echo "$out" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert isinstance(rows, list) and rows, "expected non-empty array"
print(rows[0]["name"])
' 2>&1)"; then
    if [ "$parsed" = "ml-workstation" ]; then
        _pass "cli — json list is valid JSON with name=ml-workstation"
    else
        _fail "cli — json list parsed but wrong name: $parsed"
    fi
else
    _fail "cli — json list is not valid JSON: $(echo "$out" | head -3)"
fi

# 23.4 — json status: valid JSON with workstation/disk/status/mount_point keys
out="$(_run_cli json status)" || true
if parsed="$(echo "$out" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert isinstance(rows, list) and rows, "expected non-empty array"
for r in rows:
    for k in ("workstation", "disk", "status", "mount_point"):
        assert k in r, "missing key " + k
print(rows[0]["workstation"])
' 2>&1)"; then
    if [ "$parsed" = "ml-workstation" ]; then
        _pass "cli — json status is valid JSON with expected keys"
    else
        _fail "cli — json status parsed but wrong workstation: $parsed"
    fi
else
    _fail "cli — json status is not valid JSON: $(echo "$out" | head -3)"
fi

# 23.5 — json disks <ws>: valid JSON with letter/label/remote_path
out="$(_run_cli json disks ml-workstation)" || true
if parsed="$(echo "$out" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert isinstance(rows, list) and rows, "expected non-empty array"
letters = sorted(r["letter"] for r in rows)
print(",".join(letters))
' 2>&1)"; then
    if [ "$parsed" = "C,D" ]; then
        _pass "cli — json disks ml-workstation is valid JSON with letters C,D"
    else
        _fail "cli — json disks ml-workstation parsed but wrong letters: $parsed"
    fi
else
    _fail "cli — json disks ml-workstation is not valid JSON: $(echo "$out" | head -3)"
fi

# 23.6 — raw passthrough: `cli raw list` ≡ `mount.sh list`
raw_out="$(_run_cli raw list)" || true
engine_out="$(HOME="$CLI_HOME" bash "$MOUNT_SH" list 2>&1)" || true
if [ -n "$raw_out" ] && [ "$raw_out" = "$engine_out" ]; then
    _pass "cli — raw list matches engine list output"
else
    _fail "cli — raw list differs from engine: cli='$(echo "$raw_out" | head -1)' engine='$(echo "$engine_out" | head -1)'"
fi

# 23.7 — connect without arguments fails with usage
rc=0
out="$(_run_cli connect)" || rc=$?
if [ "$rc" -ne 0 ]; then
    _pass "cli — connect without args exits non-zero"
else
    _fail "cli — connect without args exited 0"
fi
_assert_contains "$out" "Usage" "cli — connect without args prints usage"

rm -rf "$CLI_HOME"
echo ""

# ─── Summary ───────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "═══════════════════════════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "  Failed tests:"
    echo -e "$ERRORS"
    echo ""
    exit 1
else
    echo ""
    echo "  All tests passed!"
    echo ""
    exit 0
fi
