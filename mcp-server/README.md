# AutoFuse MCP Server

A Model Context Protocol (MCP) server that exposes AutoFuse capabilities to Claude Desktop, Claude Code, and other MCP-compatible clients. Provides secure, type-safe access to remote mount operations, wake-on-LAN, health monitoring, and network discovery.

## Features

- **Mount Management**: Mount/unmount remote SSHFS disks via Claude
- **Wake-on-LAN**: Remotely wake and wait for workstations
- **Health Monitoring**: Check mount health, detect stale connections, panic recovery
- **Network Discovery**: Scan networks and probe hosts
- **VPN Detection**: Detect active VPN connections and switch between LAN/VPN IPs
- **SSH Integration**: Import SSH configurations for host discovery
- **Dependency Checking**: Verify AutoFuse dependencies are installed

## Installation

### For Most Users: One-Click Menu Bar Setup (Easiest)

If you're using the AutoFuse menu bar app:

1. Click the AutoFuse menu bar icon
2. Select **"Enable Claude Integration..."**
3. Follow the wizard to install Node.js (if needed) and configure Claude
4. Restart Claude Desktop — done!

This bundles the MCP server directly in the app and handles everything automatically.

### Claude Code (one-liner)

```bash
cd mcp-server && npm install && npm run build
claude mcp add autofuse -- node "$(pwd)/dist/index.js"
```

All tools carry MCP behavior annotations (`readOnlyHint` / `destructiveHint` /
`idempotentHint`), so clients can auto-approve the 18 read-only tools and
reserve confirmation prompts for destructive ones. Known engine error codes
return with a `hint:` line guiding the agent to the next step.

### Any other MCP client

The server is plain stdio MCP — build once, then point your client at
`node <repo>/mcp-server/dist/index.js`.

**Cursor / Windsurf / Cline** (`mcp.json`, global or per-project):

```json
{
  "mcpServers": {
    "autofuse": {
      "command": "node",
      "args": ["/path/to/autofuse/mcp-server/dist/index.js"]
    }
  }
}
```

**Codex CLI** (`~/.codex/config.toml`):

```toml
[mcp_servers.autofuse]
command = "node"
args = ["/path/to/autofuse/mcp-server/dist/index.js"]
```

**Gemini CLI** (`~/.gemini/settings.json`): same `mcpServers` JSON shape as above.

**OpenClaw and other skill-based agents**: bridge MCP with a tool like
mcporter, or skip MCP entirely — the `autofuse` CLI emits stable,
machine-parseable output (`mounted_lan:/path`, `failed:<reason>`,
`host|disk|status` lines) plus JSON via `autofuse json`, so a thin
shell skill is enough:

```bash
autofuse json status   # JSON: [{workstation, disk, status, mount_point}]
autofuse status        # host|disk|status:/mount/path per line
autofuse mount ml-workstation D
autofuse heal          # repair everything broken
```

### Advanced: Manual Bash Installation

For developers or advanced users:

```bash
cd mcp-server
./install.sh
```

The installer will:
1. Build the TypeScript server
2. Install the package globally
3. Configure Claude Desktop or Claude Code automatically
4. Verify the installation

### Manual Step-by-Step Setup

1. Build the server:
```bash
npm run build
```

2. Add to Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):
```json
{
  "mcpServers": {
    "autofuse-mcp": {
      "command": "node",
      "args": ["/path/to/mcp-server/dist/index.js"]
    }
  }
}
```

3. Restart Claude Desktop or Claude Code

## Usage

Once installed, the following MCP tools are available in Claude:

### Mount Operations

- **mount_disk** - Mount a remote disk
  ```
  mount_disk(workstation="ml-workstation", disk_letter="D", use_vpn=false)
  ```

- **unmount_disk** - Unmount a remote disk
  ```
  unmount_disk(workstation="ml-workstation", disk_letter="D")
  ```

- **get_mount_status** - Check mount status
  ```
  get_mount_status(workstation="ml-workstation", disk_letter="D")
  ```

- **get_all_mount_status** - Get all mount statuses
  ```
  get_all_mount_status()
  ```

### Workstation Management

- **list_workstations** - List all configured workstations
  ```
  list_workstations()
  ```

- **get_disks** - Get available disks on a workstation
  ```
  get_disks(workstation="ml-workstation")
  ```

- **wake_workstation** - Send Wake-on-LAN signal
  ```
  wake_workstation(workstation="ml-workstation")
  ```

- **wake_and_wait** - Wake and wait for connectivity
  ```
  wake_and_wait(workstation="ml-workstation", timeout_seconds=60)
  ```

- **ping_workstation** - Check connectivity
  ```
  ping_workstation(workstation="ml-workstation")
  ```

### Health & Recovery

- **get_health_status** - Get detailed health information
  ```
  get_health_status()
  ```

- **heal_stale_mount** - Repair a stale mount
  ```
  heal_stale_mount(workstation="ml-workstation", disk_letter="D")
  ```

- **panic_check** - Identify stale or unhealthy mounts
  ```
  panic_check()
  ```

- **panic_unmount_all** - Emergency unmount all mounts
  ```
  panic_unmount_all()
  ```

### Network Discovery

- **scan_network** - Scan for available hosts
  ```
  scan_network(subnet="192.168.1.0/24")
  ```

- **probe_host** - Check if a host is reachable
  ```
  probe_host(host="192.168.1.100")
  ```

- **detect_vpn** - Check VPN status
  ```
  detect_vpn()
  ```

### System

- **check_dependencies** - Verify AutoFuse dependencies
  ```
  check_dependencies()
  ```

## Configuration

The MCP server automatically discovers AutoFuse scripts and configuration by checking:

1. Current working directory
2. Parent directory (for monorepo setups)
3. Homebrew installation (`/opt/homebrew/bin`)
4. System paths (`/usr/local/bin`)
5. macOS app bundle (`~/Applications/AutoFuse.app`)
6. Environment variable `AUTOFUSE_SCRIPTS`

Configuration files are searched in:
1. Current working directory
2. User home directory (`~/.autofuse/config.json`, `~/.config/autofuse/config.json`)
3. System location (`/etc/autofuse/config.json`)

## Architecture

```
src/
├── index.ts          # MCP server entry point with stdio transport
├── tools.ts          # Tool definitions and input schemas
├── autofuse.ts       # TypeScript wrapper for shell scripts
└── utils/            # Helper utilities
```

### Type Safety

All AutoFuse operations are wrapped with TypeScript types:

- `Workstation` - Workstation configuration
- `Disk` - Disk configuration
- `MountStatus` - Mount operation results
- `HealthInfo` - Health monitoring data
- `ProbeResult` - Network probe results
- `DiscoveryResult` - Network scan results

### Error Handling

All tool calls return structured responses:

```json
{
  "content": [
    {
      "type": "text",
      "text": "JSON response or error message"
    }
  ],
  "isError": true/false
}
```

## Development

### Build
```bash
npm run build
```

### Watch Mode
```bash
npm run dev
```

### Start Server (for testing)
```bash
npm start
```

## Security Considerations

1. **No Shell Injection**: All arguments are passed as arrays to `execFile`, preventing shell injection
2. **Script Discovery**: Searches safe locations; requires explicit environment setup
3. **Timeout Protection**: All operations have configurable timeouts (5s-120s depending on operation)
4. **Error Context**: Error messages don't expose sensitive shell output to clients
5. **Configuration Files**: Read-only access to configuration

## Dependencies

- Node.js >= 18.0.0
- AutoFuse shell scripts (`mount.sh`, `discover.sh`)
- SSHFS (via AutoFuse)
- Wake-on-LAN tools (via AutoFuse)

## Package Publication

The package is designed for npm publication:

```bash
npm publish
```

This publishes `@autofuse/mcp-server` to npm registry with:
- Compiled JavaScript in `dist/`
- TypeScript type definitions
- Source maps for debugging
- Binary entry point for global installation

## License

PolyForm Shield 1.0.0 — see [LICENSE](../LICENSE)

## Author

Fasen24-AI
