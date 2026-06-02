# SMB Protocol Support in AutoFuse

AutoFuse now supports **Server Message Block (SMB)** protocol for network file sharing, enabling direct connections to Windows file shares and SMB-enabled macOS/Linux systems.

## Overview

SMB is a network file sharing protocol commonly used by Windows systems. AutoFuse extends its capabilities to support both SSHFS (traditional SSH-based mounting) and SMB-based file sharing.

### Protocol Selection

When adding a workstation, you can choose between:
- **sshfs**: SSH-based file transfer (existing functionality, default)
- **smb**: SMB-based file sharing (new functionality)

The **Auto-Detect** button will probe the target host and automatically suggest the appropriate protocol based on port availability:
- Port 22 (SSH) and Port 445 (SMB) detection
- Preference for SSHFS if both ports are available
- Fallback to SMB-only if only port 445 is open

## Windows SMB Configuration

### Enable File Sharing on Windows

1. **Open Settings**
   - Go to Settings > System > Remote Desktop (or Settings > Network & Internet)
   - Enable "Network Discovery" and "File and Printer Sharing"

2. **Create a Shared Folder**
   - Right-click any folder in File Explorer
   - Select "Properties" > "Sharing" > "Advanced Sharing"
   - Check "Share this folder"
   - Set Share name (e.g., "AIProjects", "Documents")
   - Click "Permissions" and ensure "Everyone" has read/write access

3. **Verify Network Access**
   - Note the share path format: `//192.168.X.X/ShareName`
   - Ensure port 445 is open in Windows Firewall (or disable firewall for testing)
   - Test connectivity from another machine using `net use` (Windows) or `mount_smbfs` (macOS)

### Firewall Configuration

If you encounter connection timeouts:

**Windows Defender Firewall:**
- Open Windows Defender Firewall > Advanced Settings
- Create an Inbound Rule for port 445 (TCP)
- Allow connections from your network subnet

**Third-party Firewalls:**
- Add port 445 TCP to inbound allow list
- Or add AutoFuse/SMB to application exceptions

## macOS SMB Configuration

### macOS as SMB Server (Optional)

If you want to share files from a macOS workstation via SMB:

1. **System Preferences > Sharing**
   - Enable "File Sharing"
   - Add folders to the shared list
   - Note the SMB address (e.g., `smb://192.168.X.X`)

2. **Create a Local User (Recommended)**
   - System Preferences > Users & Groups
   - Create a user account for remote access
   - Note username and password

### Connecting to Windows SMB Shares from macOS

AutoFuse uses the built-in `mount_smbfs` utility on macOS. No additional software required.

Mounting happens automatically during the mount operation with credentials provided in your config.

## AutoFuse Configuration

### Adding an SMB Workstation

In AutoFuse's "Add Workstation" dialog:

1. **Fill Basic Details**
   - Workstation Name: `MyWindowsPC`
   - LAN IP: `192.168.1.100`
   - User: Windows username (or `guest` for anonymous)

2. **Select Protocol**
   - Choose **smb** from the Protocol dropdown

3. **Enter SMB Share Path**
   - Format: `//192.168.1.100/ShareName`
   - Example: `//192.168.1.100/AIProjects`
   - Click "Auto-Detect" to probe and auto-fill if available

4. **Add Disk Mappings (Optional)**
   - SMB shares may already be listed by Auto-Detect
   - Manual format: `ShareName, Label, //IP/Share`

5. **Save Workstation**
   - AutoFuse validates that SMB share path is non-empty
   - Configuration is saved to `config.json`

### Configuration File Format

```json
{
  "workstations": [
    {
      "name": "WindowsServer",
      "user": "Admin",
      "lan_ip": "192.168.1.100",
      "vpn_ip": "172.16.0.101",
      "protocol": "smb",
      "smb_share": "//192.168.1.100/AIProjects",
      "ssh_key": "",
      "disks": [
        {
          "letter": "AIProjects",
          "label": "AI Projects",
          "remote_path": "//192.168.1.100/AIProjects"
        }
      ]
    }
  ]
}
```

**Key Fields:**
- `protocol`: Set to `"smb"` for SMB-based sharing
- `smb_share`: The SMB share path (e.g., `//192.168.1.100/ShareName`)
- `ssh_key`: Leave empty for SMB (SSH key not used)
- Remote paths for disks should use SMB format: `//IP/Share`

## Mounting SMB Shares

### Automatic Mounting

When you click "Mount" in AutoFuse for an SMB workstation:

1. AutoFuse runs `mount_smbfs` (macOS native utility)
2. Credentials are provided via the mount command
3. Share is mounted to `~/workstation/WorkstationName/`

### Manual Mounting (macOS)

For testing or manual mounting:

```bash
# Create mount point
mkdir -p ~/workstation/MyServer

# Mount SMB share
mount_smbfs //username:password@192.168.1.100/ShareName ~/workstation/MyServer

# Unmount
umount ~/workstation/MyServer
```

### Manual Mounting (Linux)

```bash
# Install cifs-utils if not present
sudo apt-get install cifs-utils  # Debian/Ubuntu

# Create mount point
sudo mkdir -p /mnt/smb_share

# Mount SMB share
sudo mount -t cifs //192.168.1.100/ShareName /mnt/smb_share \
  -o username=user,password=pass,uid=$(id -u),gid=$(id -g)

# Unmount
sudo umount /mnt/smb_share
```

## Troubleshooting

### Connection Refused (Port 445 Not Open)

**Symptom:** "Connection refused" or timeout when mounting

**Solutions:**
1. Verify port 445 is open: `nc -zv 192.168.1.X 445`
2. Check Windows Firewall allows port 445 for your network
3. If behind corporate firewall, request port 445 access
4. For VPN: ensure VPN connection is active before mounting

### Authentication Failed

**Symptom:** "Authentication error" or "Permission denied"

**Solutions:**
1. Verify credentials: username and password are correct
2. Check Windows share has proper permissions for the user
3. Try with `guest` user if anonymous access is enabled
4. Verify user account is not disabled or locked

### Share Not Found

**Symptom:** "File or folder not found" during mount

**Solutions:**
1. Verify share name spelling: `net share` on Windows shows all shares
2. Ensure share is not disabled or paused
3. Check firewall isn't blocking SMB traffic (port 445)
4. Verify IP address and network connectivity

### macOS Permission Issues

**Symptom:** Files visible but cannot read/write

**Solutions:**
1. Check file permissions on Windows share
2. Verify SMB user has read/write access to files
3. Ensure macOS user mounting the share has local permissions
4. Check for "defer_permissions" setting in config (should be true for SMB)

### Performance Issues

**Symptoms:** Slow reads/writes, frequent timeouts

**Solutions:**
1. Check network latency: `ping -c 5 192.168.1.X`
2. Verify no network congestion or packet loss
3. Check Windows host CPU/disk usage
4. Consider SSHFS for high-latency networks (more robust)
5. Increase SSH timeout in config if using VPN

## Security Considerations

### Best Practices

1. **Use Strong Passwords**
   - Store SMB credentials securely
   - Don't use default/guest accounts for sensitive shares

2. **Network Isolation**
   - Keep SMB to LAN only if possible
   - Don't expose port 445 to public networks

3. **Access Control**
   - Create dedicated SMB user accounts for remote access
   - Restrict permissions to necessary folders only
   - Regular password rotation

4. **Auditing**
   - Enable SMB logging on Windows servers
   - Monitor access to sensitive shares
   - Check AutoFuse logs for mount failures

### Credential Storage

AutoFuse stores SMB credentials in plaintext in `config.json`. For production use:

1. **Restrict File Permissions**
   ```bash
   chmod 600 ~/.config/autofuse/config.json
   ```

2. **Alternative: SSH Tunneling**
   - Use SSHFS instead if SSH access available
   - More secure and logs SSH connections

3. **Future Enhancement**
   - Encrypted credential storage planned
   - Keychain integration for macOS

## Protocol Comparison

| Feature | SSHFS | SMB |
|---------|-------|-----|
| Authentication | SSH key or password | Username/password |
| Performance | High (binary protocol) | Medium (network dependent) |
| Compatibility | Linux, macOS, Windows (WSL) | Windows, macOS, Linux |
| Security | Strong (SSH encryption) | Moderate (SMB v3 encrypted) |
| Setup Complexity | Moderate (SSH required) | Simple (native support) |
| Best For | Servers, Linux hosts | Windows shares, LAN SMB |

## AutoFuse Code Changes

### Files Modified

1. **config.json schema**
   - Added `protocol` field (default: "sshfs")
   - Added `smb_share` field for SMB share path

2. **discover.sh**
   - Extended port scanning for port 445 (SMB)
   - Protocol auto-detection based on port availability
   - SMB availability reporting

3. **mount.sh**
   - Added `_do_smb_mount()` function
   - Protocol branching in `_do_mount()`
   - SMB-specific mount and unmount handling

4. **main.m (GUI)**
   - Added protocol dropdown selector
   - Conditional SMB share field visibility
   - Auto-detect support for protocol detection

### Implementation Details

**mount_smbfs Usage:**
```bash
mount_smbfs //username:password@192.168.1.100/ShareName /mount/point
```

**macOS-specific:**
- Uses native `mount_smbfs` utility
- No external dependencies
- Automatic credential handling
- Proper unmounting via `umount`

## Backward Compatibility

All existing SSHFS configurations remain compatible:
- Default protocol: "sshfs"
- Existing workstations without protocol field default to SSHFS
- No changes to SSHFS behavior or configuration format

## Future Enhancements

Planned improvements:

1. **Windows SMB Client**
   - Native SMB mounting on Windows
   - Local network share integration

2. **SMB v3 Support**
   - Enhanced encryption and signing
   - Performance improvements

3. **Credential Management**
   - Encrypted credential storage
   - Keychain/Credential Manager integration
   - Per-share credential override

4. **Advanced Features**
   - SMB-specific caching options
   - Bandwidth throttling
   - Automatic share discovery
   - SMB version selection

## Support and Issues

For SMB-related issues:

1. Check Windows Event Viewer for SMB errors
2. Enable SMB logging: `Set-SmbServerConfiguration -AuditSmb1Access $true` (PowerShell)
3. Verify Windows SMB version: 2.0 or higher required
4. Check AutoFuse logs: `~/.config/autofuse/autofuse.log`

For detailed troubleshooting, refer to Windows SMB documentation or network administration guides specific to your environment.
