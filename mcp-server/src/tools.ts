import { AutoFuse } from './autofuse.js';

interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  execute: (args: Record<string, unknown>) => Promise<unknown>;
}

// ─── Tool behavior annotations (MCP spec 2025-03-26) ────────────────────────
// Clients use these to gate confirmation prompts: read-only tools can run
// without asking, destructive ones always ask. Kept as sets (not per-tool
// fields) so the whole permission surface is auditable in one place.

export interface ToolAnnotations {
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
  idempotentHint?: boolean;
  openWorldHint?: boolean;
}

const READ_ONLY = new Set([
  'locate', 'diagnose', 'get_recent_activity', 'get_config',
  'get_mount_status', 'get_all_mount_status', 'list_workstations',
  'get_disks', 'check_for_stuck_mounts', 'panic_check', 'get_health_status',
  'ping_workstation', 'scan_network', 'probe_host', 'detect_vpn',
  'check_dependencies', 'verify_host_key', 'pick_endpoint',
]);

// No reach beyond this Mac (config/log/mount-table reads).
const LOCAL_ONLY = new Set([
  'get_config', 'list_workstations', 'get_disks', 'get_recent_activity',
  'check_dependencies', 'locate',
]);

const DESTRUCTIVE = new Set([
  'unmount_disk', 'quick_disconnect', 'force_unmount_all',
  'panic_unmount_all', 'run_local_shell', 'run_remote_shell',
]);

// Safe to retry with the same arguments.
const IDEMPOTENT = new Set([
  'quick_connect', 'quick_disconnect', 'fix_it', 'mount_disk', 'unmount_disk',
  'reconnect_disk', 'heal_stale_mount', 'force_unmount_all',
  'panic_unmount_all', 'wake_workstation', 'wake_and_wait', 'learn_host_key',
  'open_in_finder', 'reveal_in_finder',
]);

export function annotationsFor(name: string): ToolAnnotations {
  if (READ_ONLY.has(name)) {
    return { readOnlyHint: true, openWorldHint: !LOCAL_ONLY.has(name) };
  }
  return {
    destructiveHint: DESTRUCTIVE.has(name),
    idempotentHint: IDEMPOTENT.has(name),
    openWorldHint: true,
  };
}

const autofuse = new AutoFuse();

// ────────────────────────────────────────────────────────────────────────────
// Tool catalog — ordered by intent level (high → low).
//
// Description template: one-line action + "when to use" + "returns" + "errors".
// LLM callers select tools by matching user intent to description — terse
// descriptions get called less accurately. Each tool here names the typical
// user phrasing it maps to.
// ────────────────────────────────────────────────────────────────────────────

export const tools: ToolDefinition[] = [

  // ═══ INTENT-LEVEL · one call for common user goals ═════════════════════

  {
    name: 'quick_connect',
    description:
      "Connect to a workstation end-to-end: ping, Wake-on-LAN if asleep, then mount every configured disk. Use when the user says 'connect to X', 'get me on X', 'bring up X', or 'I want to work on X'. One call replaces the manual chain ping→wake→poll→mount-per-disk. Returns a per-disk status plus a natural-language summary. Falls back gracefully if WoL isn't configured or the host stays offline.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name from config (e.g. "ml-workstation")' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.quickConnect(args.workstation as string),
  },

  {
    name: 'quick_disconnect',
    description:
      "Disconnect from a workstation: unmount every configured disk. Use when the user says 'disconnect X', 'detach X', 'close X', 'I'm done with X'. Idempotent — calling on already-unmounted disks is safe. Returns per-disk status + summary. Does NOT power off the remote server; for that use a direct shutdown command via run_remote_shell.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name from config' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.quickDisconnect(args.workstation as string),
  },

  {
    name: 'fix_it',
    description:
      "Auto-diagnose and repair common problems: stuck/stale mounts, broken connections, host-key mismatches. Use when the user says 'it's broken', 'something's wrong', 'fix my mounts', 'nothing works'. Pass a workstation name to scope the fix to one machine, or omit to sweep the whole system. Reports every action taken and remaining issues. Safe to run any time — no-op if healthy.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Optional — narrow the fix to one workstation' },
      },
      required: [],
    },
    execute: async (args) => autofuse.fixIt(args.workstation as string | undefined),
  },

  {
    name: 'locate',
    description:
      "Find where a workstation is right now: which endpoint is reachable, whether its host key matches the stored fingerprint, which IP would be used for a mount. Use for 'is X online?', 'where is X?', 'can I reach X?'. Returns chosen_endpoint (null if offline), per-endpoint reachability list, and a human-readable summary.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.locate(args.workstation as string),
  },

  {
    name: 'diagnose',
    description:
      "Run a full diagnostic report on a workstation: every configured endpoint's reachability + RTT, SSH/SMB port status, host-key match, mount state per disk, and a best-endpoint recommendation. Use when the user says 'something is wrong with X', 'why can't I mount X', 'diagnose X', 'give me the full status of X'. Returns { workstation, report } where report is a human-readable text block — interpret it or relay it to the user as-is. Covers ~90% of 'is my mount broken?' questions in one call.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name from config' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.diagnose(args.workstation as string),
  },

  {
    name: 'get_recent_activity',
    description:
      "Tail the AutoFuse log. Use for 'what happened?', 'show recent activity', 'why did my mount fail?', 'has WoL worked?'. The log captures every mount, unmount, heal, panic, wake, host-key operation with timestamps. Returns entries (newest last) + log file path.",
    inputSchema: {
      type: 'object',
      properties: {
        lines: { type: 'number', description: 'How many recent entries to return (default 30)' },
      },
      required: [],
    },
    execute: async (args) => autofuse.getRecentActivity(args.lines as number | undefined),
  },

  {
    name: 'get_config',
    description:
      "Return the full AutoFuse configuration (~/.config/autofuse/config.json) as a parsed object. Use for 'show my config', 'what workstations do I have', 'what settings am I running'. Includes workstations, SSH/cache/IO options, mount base — the whole user config. Never exposes SSH private key content (only the path).",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => autofuse.getConfig(),
  },

  // ═══ MOUNTS · granular operations ══════════════════════════════════════

  {
    name: 'mount_disk',
    description:
      "Mount one specific disk from a workstation. Use for 'mount X's C drive', 'connect just D on ml-workstation'. For mounting everything, prefer quick_connect. Returns {workstation, disk, status, mount_point} — status starts with 'mounted_' on success (e.g. mounted_lan, mounted_vpn, mounted_wol_lan) or 'failed' with error string in mount_point.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        disk_letter: { type: 'string', description: 'Disk letter (C, D, etc.)' },
      },
      required: ['workstation', 'disk_letter'],
    },
    execute: async (args) => autofuse.mountDisk(
      args.workstation as string,
      args.disk_letter as string,
    ),
  },

  {
    name: 'unmount_disk',
    description:
      "Unmount one specific disk. Use for 'detach X's D drive'. For unmounting everything, prefer quick_disconnect. Idempotent. Returns same shape as mount_disk.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        disk_letter: { type: 'string', description: 'Disk letter' },
      },
      required: ['workstation', 'disk_letter'],
    },
    execute: async (args) => autofuse.unmountDisk(
      args.workstation as string,
      args.disk_letter as string,
    ),
  },

  {
    name: 'get_mount_status',
    description:
      "Check whether one disk is currently mounted. Returns {workstation, disk, status, mount_point}. Status is 'mounted', 'unmounted', or 'stale' (in mount table but unresponsive). Use this before mount_disk to avoid redundant calls; use before open_in_finder to know whether to mount first.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        disk_letter: { type: 'string', description: 'Disk letter' },
      },
      required: ['workstation', 'disk_letter'],
    },
    execute: async (args) => autofuse.getStatus(
      args.workstation as string,
      args.disk_letter as string,
    ),
  },

  {
    name: 'get_all_mount_status',
    description:
      "Check the status of every configured disk across every workstation in one call. Use for 'what's mounted?', 'show me everything'. Cheaper than looping get_mount_status. Returns array of {workstation, disk, status, mount_point}.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => ({ statuses: await autofuse.getStatusAll() }),
  },

  {
    name: 'list_workstations',
    description:
      "List every workstation configured in AutoFuse. Use for 'what machines can I connect to?', 'show my servers'. Returns array of {name, lan_ip, vpn_ip, disks: [disk_letters], mac_address}. The disks field is just the letters — call get_disks to get full disk records.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => ({ workstations: await autofuse.listWorkstations() }),
  },

  {
    name: 'get_disks',
    description:
      "Get the full disk records for one workstation (letter + label + remote_path). Use when you need the remote path — e.g. before telling the user 'your D drive is /D:/ on ml-workstation'.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => ({ disks: await autofuse.getDisks(args.workstation as string) }),
  },

  // ═══ RECOVERY · reconnect stuck mounts, emergency cleanup ══════════════

  {
    name: 'reconnect_disk',
    description:
      "Reconnect a single disk whose mount went stuck/stale (mount table says mounted, but reads hang). Use when the user says 'X/C is frozen', 'my D drive is hung', or before giving up on a stuck folder. Internally: detect stale → kill sshfs → remount. Alias: heal_stale_mount.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        disk_letter: { type: 'string', description: 'Disk letter' },
      },
      required: ['workstation', 'disk_letter'],
    },
    execute: async (args) => autofuse.healStale(
      args.workstation as string,
      args.disk_letter as string,
    ),
  },

  {
    name: 'heal_stale_mount',
    description: '[alias for reconnect_disk — prefer the newer name]',
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string' },
        disk_letter: { type: 'string' },
      },
      required: ['workstation', 'disk_letter'],
    },
    execute: async (args) => autofuse.healStale(
      args.workstation as string,
      args.disk_letter as string,
    ),
  },

  {
    name: 'check_for_stuck_mounts',
    description:
      "Scan every mount for 'stale' state (mount table says it's alive, but ls/stat hangs) and force-clean any found. Use for 'check if anything is stuck', 'diagnose mounts', 'something feels frozen'. Safe to run any time — no-op when all mounts are healthy. Alias: panic_check.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => ({ results: await autofuse.panicCheck() }),
  },

  {
    name: 'panic_check',
    description: '[alias for check_for_stuck_mounts — prefer the newer name]',
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => ({ results: await autofuse.panicCheck() }),
  },

  {
    name: 'force_unmount_all',
    description:
      "Emergency unmount everything: SIGKILL all sshfs processes + force unmount with 3s timeout. Use ONLY when the network is dead and Finder is about to freeze (or already has). Prefer quick_disconnect for normal disconnect. This is a last-resort operation. Alias: panic_unmount_all.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => autofuse.panicUnmountAll(),
  },

  {
    name: 'panic_unmount_all',
    description: '[alias for force_unmount_all — prefer the newer name]',
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => autofuse.panicUnmountAll(),
  },

  {
    name: 'get_health_status',
    description:
      "Per-mount latency + throughput dashboard. Use for 'how fast is my mount?', 'is the connection healthy?'. Returns {health: [{workstation, disk, status, latency_ms, throughput_kbps, uptime_secs, mount_point}]}. Zero values on unmounted disks.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => ({ health: await autofuse.getHealthJson() }),
  },

  // ═══ WAKE & CONNECTIVITY ═══════════════════════════════════════════════

  {
    name: 'wake_workstation',
    description:
      "Send a Wake-on-LAN magic packet to a workstation. Use for 'wake up X', 'power on X'. Does NOT wait for the machine to come online — call wake_and_wait for that, or use quick_connect which handles both. Requires mac_address in config.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.wakeComputer(args.workstation as string),
  },

  {
    name: 'wake_and_wait',
    description:
      "Send WoL + poll the host until it becomes SSH-reachable (or timeout). Use for 'wake X and wait'. For most cases quick_connect is better — it does this implicitly. Returns {success, latency_ms, message}.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        timeout_seconds: { type: 'number', description: 'Max seconds to wait (default 60)' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.wakeAndWait(
      args.workstation as string,
      args.timeout_seconds as number | undefined,
    ),
  },

  {
    name: 'ping_workstation',
    description:
      "Quick reachability check — pings lan_ip then vpn_ip. Returns {workstation, reachable, via} where via is 'lan:<ip>', 'vpn:<ip>', or 'unknown'. Use for 'is X online?' when you don't need host-key verification. For richer info use locate.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.pingCheck(args.workstation as string),
  },

  // ═══ DISCOVERY · find new workstations, probe unknown hosts ════════════

  {
    name: 'scan_network',
    description:
      "Scan the local subnet for hosts with SSH (port 22) and/or SMB (port 445) open. Use for 'find machines on my network', 'what's around me?'. Returns {hosts: [{ip, hostname, mac, ssh_open, smb_open}]}. Takes 5-15 seconds.",
    inputSchema: {
      type: 'object',
      properties: {
        subnet: { type: 'string', description: 'CIDR like 192.168.1.0/24 (optional — auto-detect default)' },
      },
      required: [],
    },
    execute: async (args) => autofuse.scanNetwork(args.subnet as string | undefined),
  },

  {
    name: 'probe_host',
    description:
      "Probe a single IP/hostname for AutoFuse-relevant info: detected OS, available disks, MAC address, SMB availability. Use when the user mentions an IP or hostname not yet in config — 'probe 192.168.1.50', 'what's at home-server.local'. Returns a rich object with partial info even when some probes fail.",
    inputSchema: {
      type: 'object',
      properties: {
        host: { type: 'string', description: 'IP address or hostname' },
      },
      required: ['host'],
    },
    execute: async (args) => autofuse.probeHost(args.host as string),
  },

  {
    name: 'detect_vpn',
    description:
      "List VPN / overlay interfaces currently active on this Mac (Tailscale, WireGuard, OpenVPN, WifiMan). Use for 'am I on VPN?', 'is Tailscale up?'. Returns {vpn_active, vpns: [{iface, ip, type, gateway}]}.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => autofuse.detectVPN(),
  },

  {
    name: 'check_dependencies',
    description:
      "Verify sshfs + FUSE-T/macFUSE are installed. Use when a mount fails mysteriously and you suspect the backend. Returns {satisfied, missing}. If satisfied is false, missing[0] names what to install.",
    inputSchema: { type: 'object', properties: {}, required: [] },
    execute: async () => autofuse.checkDeps(),
  },

  // ═══ HOST-KEY IDENTITY ═══════════════════════════════════

  {
    name: 'learn_host_key',
    description:
      "Capture the remote SSH host-key SHA256 fingerprint and store it in config. Enables cross-network machine identity: after this, mounts verify the fingerprint on every endpoint and refuse if none match. Use when: (a) setting up a new workstation and you're on a trusted network, (b) after a legitimate server reinstall makes the old fingerprint stale. Returns {workstation, endpoint, fingerprint}. Overwrites any existing fingerprint.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.learnHostKey(args.workstation as string),
  },

  {
    name: 'verify_host_key',
    description:
      "Check the stored fingerprint against every configured endpoint (lan/vpn/additional/mDNS). Per-endpoint report: match / mismatch / unreachable / keyscan_failed. Use to investigate 'why can't I mount?', 'did someone change my server?'. Returns {results: [...], any_match}. If any_match is false with a stored fingerprint → either network problem or someone rotated/impersonated the server.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.verifyHostKey(args.workstation as string),
  },

  {
    name: 'pick_endpoint',
    description:
      "Return which IP AutoFuse would use right now for this workstation (host-key-verified when a fingerprint is stored; otherwise first reachable). Use for 'which IP am I using?', 'where does AutoFuse route to?'. Returns {endpoint: string | null}. null means no reachable endpoint.",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
      },
      required: ['workstation'],
    },
    execute: async (args) => autofuse.pickEndpoint(args.workstation as string),
  },

  // ═══ FINDER ════════════════════════════════════════════════════════════

  {
    name: 'open_in_finder',
    description:
      "Open a mounted disk in Finder at its root. Use for 'show me my files on X/D', 'open the drive in Finder'. If the disk is not currently mounted, returns {opened: false, reason} — caller should mount_disk first (or use quick_connect).",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        disk_letter: { type: 'string', description: 'Disk letter' },
      },
      required: ['workstation', 'disk_letter'],
    },
    execute: async (args) => autofuse.openInFinder(
      args.workstation as string,
      args.disk_letter as string,
    ),
  },

  {
    name: 'reveal_in_finder',
    description:
      "Reveal a specific file/folder in Finder (right-click → Reveal). Safety-gated: the path MUST be absolute AND live under a currently-mounted AutoFuse disk. Will refuse /tmp, /etc, ~/Documents, etc. Use for 'show me this file in Finder' when you know the full path.",
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path inside a mounted AutoFuse disk' },
      },
      required: ['path'],
    },
    execute: async (args) => autofuse.revealInFinder(args.path as string),
  },

  // ═══ ARBITRARY SHELL (unrestricted, by owner choice) ═══════════════════

  {
    name: 'run_local_shell',
    description:
      "Run any shell command on the user's Mac via /bin/bash. Unrestricted — for mdfind, osascript, git, brew, system_profiler, df, ls, curl, anything. Use when no dedicated tool exists for what the user wants. Returns {stdout, stderr, exit_code, truncated}. Default 300s timeout, 10 MB output cap.",
    inputSchema: {
      type: 'object',
      properties: {
        command: { type: 'string', description: 'Command for /bin/bash -c' },
        timeout_seconds: { type: 'number', description: 'Timeout in seconds (default 300)' },
      },
      required: ['command'],
    },
    execute: async (args) => autofuse.runLocalShell(
      args.command as string,
      (args.timeout_seconds ?? args.timeout) as number | undefined,
    ),
  },

  {
    name: 'run_remote_shell',
    description:
      "Run any shell command on a workstation via SSH. Automatically routes through a host-key-verified endpoint. Windows runs under cmd.exe — for PowerShell prefix with 'powershell -NoProfile -Command '. Linux/macOS run under bash. Use for 'run X on my server', 'execute Y remotely'. Returns {endpoint, stdout, stderr, exit_code}. exit_code 255 means SSH itself failed (no reachable endpoint or auth rejected).",
    inputSchema: {
      type: 'object',
      properties: {
        workstation: { type: 'string', description: 'Workstation name' },
        command: { type: 'string', description: 'Command for the remote shell' },
        timeout_seconds: { type: 'number', description: 'Timeout in seconds (default 120)' },
      },
      required: ['workstation', 'command'],
    },
    execute: async (args) => autofuse.runRemoteShell(
      args.workstation as string,
      args.command as string,
      (args.timeout_seconds ?? args.timeout) as number | undefined,
    ),
  },
];
