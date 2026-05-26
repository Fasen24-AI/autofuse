import { execFile } from 'child_process';
import { promisify } from 'util';
import * as fs from 'fs';
import * as path from 'path';

const execFileAsync = promisify(execFile);

// Types matching AutoFuse data structures.
//
// Shape matches exactly what `mount.sh list` emits today:
//   name|lan_ip|vpn_ip|letter1,letter2|mac
// so `disks` is an array of DISK LETTERS (strings), not full `Disk` records.
// Call `getDisks(name)` to resolve each letter into a full `Disk` with label
// and remote_path. Previously this interface claimed `disks: Disk[]` and the
// callers papered over it with `as unknown as Workstation` casts — meaning
// mount.sh could change its output format and TypeScript would never warn.
export interface Workstation {
  name: string;
  lan_ip: string;
  vpn_ip: string;
  disks: string[];
  mac_address: string;
}

export interface Disk {
  letter: string;
  label: string;
  remote_path: string;
  primary?: boolean;
}

// MountStatus reflects the line-oriented output of `mount.sh status`/`mount`/
// `unmount`: `<status>:<mount_point>` where <status> is one of
// `mounted`, `mounted_lan`, `mounted_vpn`, `mounted_wol_lan`, `mounted_wol_vpn`,
// `unmounted`, `stale`, `healing_stale`, `healthy`, or `failed`.
// Previous interface claimed `{disk_letter, mounted: boolean}` which did not
// match what the code actually returned, forcing `as unknown as MountStatus`
// casts. Now aligned so callers get real type-checking.
export interface MountStatus {
  workstation: string;
  disk: string;
  status: string;
  mount_point: string;
}

// ProbeResult covers both shapes AutoFuse produces:
//   - `pingCheck` returns { workstation, reachable, via } (which LAN/VPN IP worked)
//   - `probeHost` returns whatever `discover.sh probe-host` emits as JSON (a
//     richer object with os/disks/mac). Declaring both optional lets callers
//     narrow without casts.
export interface ProbeResult {
  workstation?: string;
  host?: string;
  reachable: boolean;
  via?: string;
  path?: string;
  latency_ms?: number;
  error?: string;
  disks?: Array<{ name: string; used_gb: string; total_gb: string }>;
  [key: string]: unknown; // probe-host may carry extra fields (os, mac, protocol, smb_available)
}

// HealthInfo is intentionally loose — `mount.sh health-json` emits rich JSON
// per mount, while `panic-check` emits one colon-delimited line per check.
// Keep it open-shaped so both paths can return without casts.
export interface HealthInfo {
  workstation?: string;
  disk_letter?: string;
  healthy?: boolean;
  last_accessed?: string;
  stale_since?: string;
  error?: string;
  raw?: string;
  [key: string]: unknown;
}

// DiscoveryResult matches the scan-network wire format: one row per host
// found, each carrying reachability on ports 22 (ssh) and 445 (smb).
export interface DiscoveryHost {
  ip: string;
  hostname: string;
  mac: string;
  ssh_open: boolean;
  smb_open?: boolean;
}

export interface DiscoveryResult {
  hosts: DiscoveryHost[];
}

export class AutoFuse {
  private mountScript: string;
  private discoverScript: string;
  private configPath: string;

  constructor() {
    this.mountScript = this.findScript('mount.sh');
    this.discoverScript = this.findScript('discover.sh');
    this.configPath = this.findConfig();
  }

  private findScript(scriptName: string): string {
    // When Claude Code spawns the MCP server from a user shell, process.cwd()
    // is typically $HOME — not the project dir. So the dev-path candidates
    // almost never match. The macOS app bundle is the reliable fallback.
    // Order: explicit env var (for tests + unusual installs) → bundle →
    // dev paths (in case MCP is run from the project dir) → system paths.
    // Bundle stores scripts under Contents/Resources/ (not MacOS/ — that
    // holds the executable binary). Previous revision had MacOS/ and
    // silently failed with "mount.sh not found" until restart.
    const candidates = [
      process.env.AUTOFUSE_SCRIPTS
        ? path.join(process.env.AUTOFUSE_SCRIPTS, scriptName)
        : null,
      // Installed app bundles (primary path for user installs)
      path.join(process.env.HOME || '', 'Applications/AutoFuse.app/Contents/Resources', scriptName),
      `/Applications/AutoFuse.app/Contents/Resources/${scriptName}`,
      // Homebrew / system paths
      path.join('/opt/homebrew/bin', scriptName),
      path.join('/usr/local/bin', scriptName),
      // Development fallback LAST: when Claude Code spawns the MCP, cwd is the
      // user's workspace — an unrelated repo's mount.sh must NOT win over the
      // installed AutoFuse.
      path.join(process.cwd(), scriptName),
      path.join(process.cwd(), '..', scriptName),
    ].filter((p): p is string => p !== null);

    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }

    throw new Error(
      `${scriptName} not found. Searched: ${candidates.join(', ')}`
    );
  }

  private findConfig(): string {
    // Match mount.sh priority exactly: user config ALWAYS wins. The repo /
    // bundle config is only a first-run template. Earlier revisions had
    // `cwd/config.json` first, which made the MCP server silently read the
    // stale bundle template whenever invoked from the project dir, while
    // mount.sh read the user file — two different views of the same "config"
    // depending on which layer the caller came through. Fixed by putting
    // user paths first and repo paths last.
    const home = process.env.HOME || '';
    const candidates = [
      path.join(home, '.config/autofuse/config.json'),  // primary user config
      path.join(home, '.autofuse/config.json'),          // legacy user location
      '/etc/autofuse/config.json',                        // system-wide
      path.join(process.cwd(), 'config.json'),           // dev / bundle fallback
      path.join(process.cwd(), '..', 'config.json'),
    ];

    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }

    return candidates[0];
  }

  private async exec(
    script: string,
    args: string[],
    timeout: number = 30000
  ): Promise<string> {
    try {
      const { stdout } = await execFileAsync(script, args, {
        timeout,
        maxBuffer: 1024 * 1024 * 10,
        env: {
          ...process.env,
          PATH: [
            '/opt/homebrew/bin',
            '/usr/local/bin',
            '/usr/bin',
            '/bin',
            process.env.PATH,
          ]
            .filter(Boolean)
            .join(':'),
        },
      });
      return stdout.trim();
    } catch (error: any) {
      const message =
        error.stderr || error.message || 'Script execution failed';
      const err = new Error(`${path.basename(script)} error: ${message}`) as Error & { stdout?: string };
      // Preserve stdout from the failing command so callers that can extract
      // useful partial info (e.g. probe-host returning `protocol\tsshfs`
      // before erroring on OS detection) can do so.
      err.stdout = typeof error.stdout === 'string' ? error.stdout.trim() : '';
      throw err;
    }
  }

  // For commands that use the EXIT CODE as a semantic signal (mount failed,
  // WoL timed out, host-key mismatch) while putting the real result on stdout.
  // mount.sh does this pervasively, but execFile rejects on non-zero exit and
  // Node only surfaces stderr — so the meaningful stdout was lost and callers
  // saw an opaque "Command failed". Return stdout whenever present; only a
  // genuine spawn failure (empty stdout) re-throws.
  private async execStatus(script: string, args: string[], timeout = 30000): Promise<string> {
    try {
      return await this.exec(script, args, timeout);
    } catch (e) {
      const err = e as { stdout?: string };
      if (err.stdout && err.stdout.length > 0) return err.stdout;
      throw e;
    }
  }

  // Last non-empty line of an output. mount.sh prints progress lines
  // (trying_wol, wol_waiting, healing_stale, …) BEFORE the terminal result
  // line; parsing the whole blob as one record mis-reads the status.
  private lastLine(output: string): string {
    const lines = output.split('\n').map((l) => l.trim()).filter(Boolean);
    return lines.length ? lines[lines.length - 1] : '';
  }

  async listWorkstations(): Promise<Workstation[]> {
    const output = await this.exec(this.mountScript, ['list'], 10000);
    if (!output) return [];
    // Format: name|lan_ip|vpn_ip|disk1,disk2|mac
    return output.split('\n').filter(Boolean).map((line: string): Workstation => {
      const [name, lan_ip, vpn_ip, disks, mac] = line.split('|');
      return {
        name: name ?? '',
        lan_ip: lan_ip ?? '',
        vpn_ip: vpn_ip ?? '',
        disks: disks ? disks.split(',').filter(Boolean) : [],
        mac_address: mac ?? '',
      };
    });
  }

  async getDisks(workstation: string): Promise<Disk[]> {
    const output = await this.exec(this.mountScript, ['disks', workstation], 10000);
    if (!output) return [];
    // Format: letter|label|remote_path
    return output.split('\n').filter(Boolean).map((line: string) => {
      const [letter, label, remote_path] = line.split('|');
      return { letter: letter ?? '', label: label ?? '', remote_path: remote_path ?? '' };
    });
  }

  async getStatus(workstation: string, diskLetter: string): Promise<MountStatus> {
    const output = await this.exec(this.mountScript, ['status', workstation, diskLetter], 10000);
    // Format: status:mount_point
    const [status, ...rest] = output.split(':');
    return { workstation, disk: diskLetter, status: status ?? '', mount_point: rest.join(':') };
  }

  async getStatusAll(): Promise<MountStatus[]> {
    const output = await this.exec(this.mountScript, ['status-all'], 10000);
    if (!output) return [];
    // Format: ws|disk|status:mount_point
    return output.split('\n').filter(Boolean).map((line: string) => {
      const [ws, disk, full] = line.split('|');
      const [status, ...rest] = (full || '').split(':');
      return { workstation: ws ?? '', disk: disk ?? '', status: status ?? '', mount_point: rest.join(':') };
    });
  }

  async mountDisk(workstation: string, diskLetter: string): Promise<MountStatus> {
    // status-channel command: exit 1 on failure with `failed:<mp>:<reason>` on
    // stdout; the WoL path prints progress lines before the terminal result.
    const output = await this.execStatus(this.mountScript, ['mount', workstation, diskLetter], 60000);
    const [status, ...rest] = this.lastLine(output).split(':');
    return { workstation, disk: diskLetter, status: status ?? '', mount_point: rest.join(':') };
  }

  async unmountDisk(workstation: string, diskLetter: string): Promise<MountStatus> {
    const output = await this.execStatus(this.mountScript, ['unmount', workstation, diskLetter], 30000);
    const [status, ...rest] = this.lastLine(output).split(':');
    return { workstation, disk: diskLetter, status: status ?? '', mount_point: rest.join(':') };
  }

  async wakeComputer(workstation: string): Promise<{ success: boolean; message: string }> {
    const output = await this.execStatus(this.mountScript, ['wol', workstation], 10000);
    return { success: output.includes('wol_sent'), message: output };
  }

  async wakeAndWait(workstation: string, timeout?: number): Promise<{ success: boolean; latency_ms: number; message: string }> {
    const args = ['wol-wait', workstation];
    if (timeout) args.push(timeout.toString());
    // The exec timeout must outlast the wol-wait poll window, otherwise SIGTERM
    // kills it mid-boot and the result is an opaque "Command failed".
    const execTimeout = Math.max(120000, ((timeout ?? 60) + 30) * 1000);
    const output = await this.execStatus(this.mountScript, args, execTimeout);
    return { success: output.includes('wol_online') || output.includes('wol_sent'), latency_ms: 0, message: output };
  }

  async healStale(workstation: string, diskLetter: string): Promise<MountStatus> {
    // status-channel + multi-line: `healing_stale:<mp>` precedes the result.
    const output = await this.execStatus(this.mountScript, ['heal', workstation, diskLetter], 60000);
    const [status, ...rest] = this.lastLine(output).split(':');
    return { workstation, disk: diskLetter, status: status ?? '', mount_point: rest.join(':') };
  }

  async panicUnmountAll(): Promise<{ unmounted: MountStatus[] }> {
    const output = await this.exec(this.mountScript, ['panic-unmount-all'], 30000);
    return {
      unmounted: [
        {
          workstation: 'all',
          disk: 'all',
          status: output.includes('complete') ? 'unmounted' : 'error',
          mount_point: output,
        },
      ],
    };
  }

  async panicCheck(): Promise<HealthInfo[]> {
    const output = await this.exec(this.mountScript, ['panic-check'], 30000);
    if (!output) return [];
    return output.split('\n').filter(Boolean).map((line: string): HealthInfo => ({ raw: line }));
  }

  async pingCheck(workstation: string): Promise<ProbeResult> {
    const output = await this.exec(this.mountScript, ['ping-check', workstation], 15000);
    // Format: name|result
    const parts = output.split('|');
    const result = parts[1] ?? 'offline';
    return {
      workstation: parts[0] || workstation,
      reachable: result !== 'offline',
      via: result || 'unknown',
    };
  }

  async checkDeps(): Promise<{ satisfied: boolean; missing: string[] }> {
    const output = await this.execStatus(this.mountScript, ['check-deps'], 10000);
    // Format: ok:sshfs:backend or error:reason
    const satisfied = output.startsWith('ok:');
    return { satisfied, missing: satisfied ? [] : [output] };
  }

  async getHealthJson(): Promise<HealthInfo[]> {
    const output = await this.execStatus(this.mountScript, ['health-json'], 10000);
    if (!output) return [];
    // mount.sh emits {"health": [...]} — unwrap so callers (and the tool's
    // declared {health:[...]} shape) don't get a doubly-nested {health:{health}}.
    try {
      const parsed = JSON.parse(output);
      return Array.isArray(parsed) ? parsed : (parsed.health ?? [{ raw: output }]);
    } catch {
      return [{ raw: output }];
    }
  }

  async scanNetwork(subnet?: string): Promise<DiscoveryResult> {
    const args = ['scan-network'];
    if (subnet) args.push(subnet);
    const output = await this.exec(this.discoverScript, args, 120000);
    // Format: ip|hostname|mac|ssh_open per line
    const hosts: DiscoveryHost[] = output.split('\n').filter(Boolean).map((line: string) => {
      const [ip, hostname, mac, ssh, smb] = line.split('|');
      return {
        ip: ip ?? '',
        hostname: hostname ?? '',
        mac: mac ?? '',
        ssh_open: ssh === 'yes',
        smb_open: smb === 'yes',
      };
    });
    return { hosts };
  }

  // discover.sh probe-host emits tab-separated `key\tvalue` lines plus
  // `disk\tletter|label|path` rows — NOT JSON, despite what an earlier
  // revision of this wrapper assumed. Parse the actual format so an LLM
  // client (Claude Desktop / Code) gets a structured object instead of a
  // JSON-parse failure. Errors are surfaced as `error` field, not thrown,
  // so the caller can still see the partial info (e.g. protocol detected
  // but OS detection failed because key auth isn't set up yet).
  async probeHost(host: string): Promise<ProbeResult> {
    // probe-host exits non-zero when OS detection fails (e.g. SSH key auth
    // not set up yet), but the partial output — protocol, smb_available —
    // is still valuable to the caller. Capture stdout from the throw path
    // and parse regardless.
    let output: string;
    try {
      output = await this.exec(this.discoverScript, ['probe-host', host], 15000);
    } catch (e) {
      const err = e as { stdout?: string; message?: string };
      output = err.stdout || err.message || '';
    }
    const result: ProbeResult = { host, reachable: false };
    const disks: Array<{ name: string; used_gb: string; total_gb: string }> = [];
    for (const line of output.split('\n')) {
      if (!line) continue;
      if (line.startsWith('error:')) {
        result.error = line.slice('error:'.length);
        continue;
      }
      if (line.startsWith('disk\t')) {
        // discover.sh emits `disk\t<name>||<used_gb>|<total_gb>` (4 fields,
        // empty 2nd) — NOT letter|label|remote_path.
        const [name, , used_gb, total_gb] = line.slice(5).split('|');
        disks.push({ name: name ?? '', used_gb: used_gb ?? '', total_gb: total_gb ?? '' });
        continue;
      }
      const tab = line.indexOf('\t');
      if (tab > 0) {
        const k = line.slice(0, tab);
        const v = line.slice(tab + 1);
        result[k] = v;
      }
    }
    if (disks.length > 0) result.disks = disks;
    result.reachable = !result.error;
    return result;
  }

  // discover.sh detect-vpn emits pipe-delimited `iface|ip|type|gateway` lines
  // for each active VPN, OR nothing at all when no VPN is up. Empty output is
  // the normal "no VPN active" case — we must not throw for it.
  async detectVPN(): Promise<{ vpn_active: boolean; vpns: Array<{ iface: string; ip: string; type: string; gateway: string }>; gateway?: string }> {
    const output = await this.exec(this.discoverScript, ['detect-vpn'], 5000);
    if (!output.trim()) return { vpn_active: false, vpns: [] };
    const vpns = output.split('\n').filter(Boolean).map((line) => {
      const [iface, ip, type, gateway] = line.split('|');
      return { iface: iface ?? '', ip: ip ?? '', type: type ?? '', gateway: gateway ?? '' };
    });
    return {
      vpn_active: vpns.length > 0,
      vpns,
      gateway: vpns[0]?.gateway || undefined,
    };
  }

  // ─── Host-key identity ────────────────────────────────────

  // Capture the SSH host-key SHA256 fingerprint of the first reachable endpoint
  // and store it in config.json. Idempotent — fails with a clear error if no
  // fingerprint could be captured (e.g. host offline).
  async learnHostKey(workstation: string): Promise<{ workstation: string; endpoint: string; fingerprint: string }> {
    const output = await this.execStatus(this.mountScript, ['learn-host-key', workstation], 10000);
    // Format on success: learned:<ws>|<endpoint>|<sha>
    if (output.startsWith('learned:')) {
      const [ws, endpoint, fingerprint] = output.slice('learned:'.length).split('|');
      return { workstation: ws ?? workstation, endpoint: endpoint ?? '', fingerprint: fingerprint ?? '' };
    }
    throw new Error(`learn-host-key failed: ${output}`);
  }

  // Report each endpoint's verification status against the stored fingerprint.
  // Lines are one of: match:<host>|<sha>, mismatch:<host>|<sha>|expected:<sha>,
  // keyscan_failed:<host>, unreachable:<host>. Returns structured records so
  // an LLM caller can reason about partial trust (some endpoints match, some
  // don't).
  async verifyHostKey(workstation: string): Promise<{ results: Array<{ endpoint: string; state: string; fingerprint?: string; expected?: string }>; any_match: boolean }> {
    const output = await this.execStatus(this.mountScript, ['verify-host-key', workstation], 15000);
    const results: Array<{ endpoint: string; state: string; fingerprint?: string; expected?: string }> = [];
    let any_match = false;
    for (const line of output.split('\n').filter(Boolean)) {
      const [state, rest] = [line.split(':', 1)[0], line.slice(line.indexOf(':') + 1)];
      const parts = rest.split('|');
      if (state === 'match') {
        any_match = true;
        results.push({ endpoint: parts[0] ?? '', state, fingerprint: parts[1] });
      } else if (state === 'mismatch') {
        const expectedPart = (parts[2] ?? '').replace(/^expected:/, '');
        results.push({ endpoint: parts[0] ?? '', state, fingerprint: parts[1], expected: expectedPart });
      } else {
        results.push({ endpoint: parts[0] ?? rest, state });
      }
    }
    return { results, any_match };
  }

  // Returns the first endpoint that satisfies `_pick_endpoint` rules. When a
  // fingerprint is stored this is key-verified; otherwise it's the first
  // reachable. Useful for the LLM to show the user "which IP would be used
  // right now" before actually mounting.
  async pickEndpoint(workstation: string): Promise<{ endpoint: string | null }> {
    try {
      const output = await this.exec(this.mountScript, ['pick-endpoint', workstation], 10000);
      return { endpoint: output.trim() || null };
    } catch {
      return { endpoint: null };
    }
  }

  // Run the comprehensive workstation diagnostic (endpoints + ports +
  // host-key + mounts + recommendations). Returns the human-readable
  // text report rather than parsed JSON: the report is dense with
  // context an LLM caller can interpret and relay to the user directly.
  // Parsing into a fixed schema would lose nuance the text layout
  // captures (e.g. port-state alignment, hint paragraph).
  async diagnose(workstation: string): Promise<{ workstation: string; report: string }> {
    // 90s timeout: diagnose runs up to 4 endpoint probes × ~3s each
    // (reachable + RTT + port-check + ssh-keyscan) plus a trailing
    // _pick_endpoint re-probe. Easily 20-40s in practice on networks
    // where some endpoints timeout. Earlier 30s was too tight and users
    // saw "Command failed" right as the report was about to print.
    const output = await this.exec(this.mountScript, ['diagnose', workstation], 90000);
    return { workstation, report: output };
  }

  // ─── Composite "intent" operations ──────────────────────────────────────
  //
  // These wrap multi-step flows into one call so LLM callers don't have to
  // orchestrate sequences like "ping → wake → poll → mount each disk".
  // Each returns a structured summary an LLM can narrate to the user.

  // "Connect me to this workstation" — does everything. Pings, wakes if
  // needed, then mounts every configured disk. Returns per-disk status.
  async quickConnect(workstation: string): Promise<{
    workstation: string;
    was_asleep: boolean;
    waked: boolean;
    reached_via: string;
    disks: Array<{ letter: string; status: string; mount_point: string }>;
    summary: string;
  }> {
    const ping = await this.pingCheck(workstation);
    let was_asleep = !ping.reachable;
    let waked = false;
    let reached_via = ping.via || 'unknown';

    if (was_asleep) {
      const wake = await this.wakeAndWait(workstation, 60);
      waked = wake.success;
      if (!waked) {
        return {
          workstation, was_asleep, waked, reached_via: 'offline',
          disks: [],
          summary: `${workstation} is offline and Wake-on-LAN did not bring it online within 60s. Check the machine or its MAC address config.`,
        };
      }
      const repin = await this.pingCheck(workstation);
      reached_via = repin.via || 'unknown';
    }

    const diskList = await this.getDisks(workstation);
    const disks = [];
    for (const d of diskList) {
      const result = await this.mountDisk(workstation, d.letter);
      disks.push({ letter: d.letter, status: result.status, mount_point: result.mount_point });
    }
    const successes = disks.filter(d => d.status.startsWith('mounted')).length;
    const summary = `${workstation} connected — ${successes}/${disks.length} disks mounted${waked ? ' (woke via WoL)' : ''}.`;
    return { workstation, was_asleep, waked, reached_via, disks, summary };
  }

  // "Disconnect me from this workstation" — unmount every disk. Idempotent.
  async quickDisconnect(workstation: string): Promise<{
    workstation: string;
    disks: Array<{ letter: string; status: string; mount_point: string }>;
    summary: string;
  }> {
    const diskList = await this.getDisks(workstation);
    const disks = [];
    for (const d of diskList) {
      const result = await this.unmountDisk(workstation, d.letter);
      disks.push({ letter: d.letter, status: result.status, mount_point: result.mount_point });
    }
    return {
      workstation, disks,
      summary: `${workstation} disconnected — ${disks.length} disks unmounted.`,
    };
  }

  // "Something's wrong, fix it" — auto-diagnoses and repairs stuck mounts,
  // host-key mismatches, and orphan sshfs processes. Reports what it did.
  async fixIt(workstation?: string): Promise<{
    actions_taken: string[];
    issues_found: string[];
    workstation?: string;
    summary: string;
  }> {
    const actions: string[] = [];
    const issues: string[] = [];

    // Step 1: find stuck mounts across the board
    const stuck = await this.panicCheck();
    const stuckLines = stuck.filter(s => (s.raw || '').includes('stale') || (s.raw || '').includes('healed'));
    if (stuckLines.length > 0) {
      issues.push(`${stuckLines.length} stuck mount(s) detected and force-cleaned.`);
      actions.push('force-cleaned stuck mounts');
    }

    // Step 2: if a workstation is specified, try heal + host-key check
    if (workstation) {
      const diskList = await this.getDisks(workstation);
      for (const d of diskList) {
        const status = await this.getStatus(workstation, d.letter);
        if (status.status === 'stale') {
          const healed = await this.healStale(workstation, d.letter);
          actions.push(`reconnected ${workstation}/${d.letter}: ${healed.status}`);
          issues.push(`${workstation}/${d.letter} was stale`);
        }
      }
      // Also verify host key if stored
      try {
        const verify = await this.verifyHostKey(workstation);
        if (!verify.any_match) {
          issues.push(`No endpoint of ${workstation} matches the stored host-key fingerprint. Run learn_host_key if this is a legitimate reinstall.`);
        }
      } catch {
        // No fingerprint stored — OK, skip
      }
    }

    const summary = issues.length === 0
      ? (workstation ? `${workstation} looks healthy — no issues found.` : 'System healthy — no stuck mounts found.')
      : `Fixed ${actions.length} issue(s). ${issues.join(' ')}`;

    return { actions_taken: actions, issues_found: issues, workstation, summary };
  }

  // "Where is this workstation right now?" — composite locate: reachability
  // per endpoint + host-key verification status + chosen endpoint.
  async locate(workstation: string): Promise<{
    workstation: string;
    online: boolean;
    chosen_endpoint: string | null;
    endpoints: Array<{ address: string; kind: string; reachable: boolean; key_status?: string }>;
    summary: string;
  }> {
    const picked = await this.pickEndpoint(workstation);
    const chosen_endpoint = picked.endpoint;
    const online = chosen_endpoint !== null;

    // Always enumerate every configured endpoint so the user sees the full
    // picture, regardless of whether a host-key fingerprint is stored.
    // Earlier revision fell through to a single-ping summary when no
    // fingerprint existed — which hid vpn_ip / additional_ips / mDNS.
    const configured = await this.listConfiguredEndpoints(workstation);
    const endpoints: Array<{ address: string; kind: string; reachable: boolean; key_status?: string }> = [];

    // Overlay host-key verification state if available, otherwise plain ping.
    let verifyResults: Array<{ endpoint: string; state: string }> | null = null;
    try {
      const verify = await this.verifyHostKey(workstation);
      verifyResults = verify.results;
    } catch {
      // no fingerprint stored; carry on with ping-only probing below
    }

    for (const c of configured) {
      const v = verifyResults?.find((r) => r.endpoint === c.address);
      if (v) {
        endpoints.push({
          address: c.address,
          kind: c.kind,
          reachable: v.state !== 'unreachable',
          key_status: v.state,
        });
      } else {
        const reachable = await this.isReachable(c.address);
        endpoints.push({ address: c.address, kind: c.kind, reachable });
      }
    }

    const verified = endpoints.some((e) => e.key_status === 'match');
    const summary = online
      ? `${workstation} is online at ${chosen_endpoint}${verified ? ' (host-key verified)' : ''}.`
      : `${workstation} is offline — none of ${endpoints.length} configured endpoint(s) responded.`;

    return { workstation, online, chosen_endpoint, endpoints, summary };
  }

  // Enumerate every configured endpoint for a workstation: lan_ip, vpn_ip,
  // additional_ips[], then <name>.local mDNS fallback. Each entry is tagged
  // with its "kind" so the caller (and LLM narrating to the user) can
  // distinguish why each address exists.
  private async listConfiguredEndpoints(
    workstation: string,
  ): Promise<Array<{ address: string; kind: 'lan' | 'vpn' | 'extra' | 'mdns' }>> {
    const cfg = JSON.parse(fs.readFileSync(this.configPath, 'utf-8'));
    const ws = cfg.workstations?.find((w: { name: string }) => w.name === workstation);
    const out: Array<{ address: string; kind: 'lan' | 'vpn' | 'extra' | 'mdns' }> = [];
    if (!ws) return out;
    if (ws.lan_ip) out.push({ address: ws.lan_ip, kind: 'lan' });
    if (ws.vpn_ip) out.push({ address: ws.vpn_ip, kind: 'vpn' });
    for (const extra of ws.additional_ips ?? []) {
      if (extra) out.push({ address: String(extra), kind: 'extra' });
    }
    out.push({ address: `${workstation}.local`, kind: 'mdns' });
    return out;
  }

  // One-shot reachability probe for a single address (host or IP). Shell out
  // to `ping -c1 -t2` — same behavior mount.sh uses internally for _reachable.
  private async isReachable(address: string): Promise<boolean> {
    try {
      await execFileAsync('/sbin/ping', ['-c', '1', '-t', '2', address], { timeout: 3000 });
      return true;
    } catch {
      return false;
    }
  }

  // "What happened recently?" — tail the log. Default 30 lines.
  async getRecentActivity(lines: number = 30): Promise<{ entries: string[]; log_path: string }> {
    const logPath = path.join(process.env.HOME || '', '.config/autofuse/autofuse.log');
    try {
      if (!fs.existsSync(logPath)) return { entries: [], log_path: logPath };
      const all = fs.readFileSync(logPath, 'utf-8').split('\n').filter(Boolean);
      // slice(-0) === slice(0) === whole array; guard so lines:0 means none.
      return { entries: lines > 0 ? all.slice(-lines) : [], log_path: logPath };
    } catch {
      return { entries: [], log_path: logPath };
    }
  }

  // "Show me my config" — returns the parsed config.json as an object.
  // Sensitive fields (none today, but future-proof) could be redacted here.
  async getConfig(): Promise<{ config_path: string; config: unknown }> {
    try {
      const content = fs.readFileSync(this.configPath, 'utf-8');
      return { config_path: this.configPath, config: JSON.parse(content) };
    } catch (e) {
      return { config_path: this.configPath, config: { error: String(e) } };
    }
  }

  // ─── Arbitrary shell execution (local + remote) ────────────────────────

  // Run a shell command locally on the user's Mac. Deliberately unrestricted:
  // the MCP server is single-tenant by design — it runs locally, as the user,
  // for the user's own MCP client, with no second tenant to isolate. The
  // permission boundary is the MCP client's per-tool approval (see SECURITY.md).
  // Caps: 300s timeout, 10 MB output (truncated with notice). Output is
  // combined stdout+stderr with a separator so callers can diagnose both.
  async runLocalShell(command: string, timeout: number = 300): Promise<{
    stdout: string; stderr: string; exit_code: number; truncated: boolean;
  }> {
    const { exec } = await import('child_process');
    const { promisify } = await import('util');
    const execP = promisify(exec);
    const maxBuffer = 10 * 1024 * 1024;
    // timeout=0 in child_process means "no timeout" (infinite hang) — clamp it.
    const t = timeout && timeout > 0 ? timeout : 300;
    try {
      const { stdout, stderr } = await execP(command, {
        timeout: t * 1000,
        maxBuffer,
        shell: '/bin/bash',
      });
      return { stdout, stderr, exit_code: 0, truncated: false };
    } catch (e: any) {
      return {
        stdout: typeof e.stdout === 'string' ? e.stdout : '',
        stderr: typeof e.stderr === 'string' ? e.stderr : (e.message || ''),
        exit_code: typeof e.code === 'number' ? e.code : 1,
        truncated: e.message?.includes('maxBuffer') ?? false,
      };
    }
  }

  // Run a shell command on a remote workstation via SSH. Leverages Feature
  // #13: uses `_pick_endpoint` so the command goes to a host-key-verified
  // endpoint when a fingerprint is stored. Key auth only (no passwords);
  // if the user's SSH key isn't accepted by the remote, this fails clean.
  //
  // Windows workstations: the remote shell is whatever OpenSSH's default
  // launches — usually cmd.exe. To run PowerShell, prefix the command with
  // `powershell -NoProfile -Command` yourself, or the helpers defined above.
  async runRemoteShell(workstation: string, command: string, timeout: number = 120): Promise<{
    endpoint: string; stdout: string; stderr: string; exit_code: number;
  }> {
    // 1. Pick a verified endpoint (key-checked if host_key_sha256 set).
    const picked = await this.pickEndpoint(workstation);
    if (!picked.endpoint) {
      return { endpoint: '', stdout: '', stderr: 'no reachable endpoint for ' + workstation, exit_code: 255 };
    }
    // 2. Load workstation record for user + ssh_key.
    const workstations = this.loadConfig();
    const ws = workstations.find((w) => w.name === workstation);
    if (!ws) {
      return { endpoint: picked.endpoint, stdout: '', stderr: `unknown workstation: ${workstation}`, exit_code: 2 };
    }
    // loadConfig returns our lightweight shape, but we need user + ssh_key
    // from the full config — re-read.
    const fullCfg = JSON.parse(fs.readFileSync(this.configPath, 'utf-8'));
    const full = fullCfg.workstations.find((w: { name: string }) => w.name === workstation);
    const sshUser: string = full?.user || process.env.USER || 'root';
    const sshKey: string = (full?.ssh_key || '~/.ssh/id_ed25519').replace(/^~/, process.env.HOME || '');
    const knownHosts = path.join(process.env.HOME || '', '.config/autofuse/known_hosts');
    // 3. Build ssh argv (array — no shell interpolation of `command`).
    const sshArgs = [
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=5',
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', `UserKnownHostsFile=${knownHosts}`,
      '-i', sshKey,
      `${sshUser}@${picked.endpoint}`,
      command,
    ];
    try {
      const { stdout, stderr } = await execFileAsync('ssh', sshArgs, {
        timeout: timeout * 1000,
        maxBuffer: 10 * 1024 * 1024,
      });
      return { endpoint: picked.endpoint, stdout, stderr, exit_code: 0 };
    } catch (e: any) {
      return {
        endpoint: picked.endpoint,
        stdout: typeof e.stdout === 'string' ? e.stdout : '',
        stderr: typeof e.stderr === 'string' ? e.stderr : (e.message || ''),
        exit_code: typeof e.code === 'number' ? e.code : 1,
      };
    }
  }

  // ─── Finder integration ────────────────────────────────────────────────

  // Resolve a workstation + disk letter to its local mount path (e.g.
  // `~/workstation-C`) by delegating to mount.sh — avoids duplicating the
  // primary/sibling/multi-ws rules in two places.
  private async mountPointFor(workstation: string, diskLetter: string): Promise<string> {
    const output = await this.exec(this.mountScript, ['status', workstation, diskLetter], 5000);
    const [, ...rest] = output.split(':');
    return rest.join(':').trim();
  }

  // Open a mounted disk in Finder at its top-level directory. If the disk is
  // not currently mounted, returns { opened: false, reason }. Useful when an
  // LLM wants to "show me my files on ml-workstation's D drive" — one tool call, the
  // Finder window appears.
  async openInFinder(workstation: string, diskLetter: string): Promise<{ opened: boolean; path?: string; reason?: string }> {
    const statusLine = await this.exec(this.mountScript, ['status', workstation, diskLetter], 5000);
    const [state, ...pathParts] = statusLine.split(':');
    const path = pathParts.join(':').trim();
    if (state !== 'mounted') {
      return { opened: false, reason: `disk is ${state} (not mounted). Mount it first with mount_disk.`, path };
    }
    await execFileAsync('/usr/bin/open', [path], { timeout: 5000 });
    return { opened: true, path };
  }

  // Reveal an arbitrary path inside a mounted disk in Finder (like right-click
  // → Reveal in Finder). Path must live under one of the configured mount
  // points — we refuse to open paths outside so an LLM cannot use this tool
  // to surface arbitrary files on the local Mac.
  async revealInFinder(absolutePath: string): Promise<{ revealed: boolean; reason?: string }> {
    if (!absolutePath.startsWith('/')) {
      return { revealed: false, reason: 'path must be absolute' };
    }
    // Resolve symlinks + `..` BEFORE the containment check: otherwise
    // `/…/workstation-C/../../../etc/hosts` (or a symlink pointing out of the
    // mount) passes a naive startsWith and reveals an arbitrary local file.
    let resolved: string;
    try {
      resolved = fs.realpathSync(absolutePath);
    } catch {
      return { revealed: false, reason: 'path does not exist' };
    }
    const all = await this.getStatusAll();
    const mounted = all.filter((s) => s.status === 'mounted').map((s) => s.mount_point).filter(Boolean);
    const insideOurMount = mounted.some((mp) => {
      let realMp: string;
      try { realMp = fs.realpathSync(mp); } catch { return false; }
      return resolved === realMp || resolved.startsWith(realMp + '/');
    });
    if (!insideOurMount) {
      return { revealed: false, reason: 'path is not under any mounted AutoFuse disk' };
    }
    await execFileAsync('/usr/bin/open', ['-R', resolved], { timeout: 5000 });
    return { revealed: true };
  }

  async importSSHConfig(): Promise<{ imported: number; total: number }> {
    const output = await this.exec(
      this.discoverScript,
      ['import-ssh-config'],
      10000
    );

    try {
      return JSON.parse(output);
    } catch {
      throw new Error('SSH config import operation failed');
    }
  }

  getConfigPath(): string {
    return this.configPath;
  }

  loadConfig(): Workstation[] {
    try {
      const content = fs.readFileSync(this.configPath, 'utf-8');
      const config = JSON.parse(content);
      return config.workstations || [];
    } catch {
      return [];
    }
  }
}
