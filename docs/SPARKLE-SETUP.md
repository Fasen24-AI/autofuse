# Sparkle Auto-Update Setup

This document covers how to set up AutoFuse with the Sparkle framework for automatic updates.

## Prerequisites

AutoFuse is compiled conditionally to support Sparkle when available. If Sparkle is not installed, AutoFuse will compile and run normally without update checking.

## Installation

### macOS (Homebrew)

```bash
brew install sparkle
```

This installs Sparkle framework to:
- ARM64 (Apple Silicon): `/opt/homebrew/opt/sparkle/Sparkle.framework`
- Intel: `/usr/local/opt/sparkle/Sparkle.framework`

The build script automatically detects and links Sparkle during compilation.

### Building with Sparkle

After installing Sparkle via Homebrew, rebuild AutoFuse:

```bash
cd /path/to/autofuse
bash build.sh
```

The build script will:
1. Detect Sparkle at standard Homebrew paths
2. Conditionally add `-framework Sparkle` to compiler flags
3. Copy Sparkle.framework into the .app bundle
4. Generate Info.plist with Sparkle update feed URL

## Configuration

### Update Feed (appcast.xml)

The update feed is configured in Info.plist as:

```xml
<key>SUFeedURL</key>
<string>https://fasen24-ai.github.io/autofuse/appcast.xml</string>
```

### Hosting the Appcast Feed

To enable updates, host an appcast.xml file on your GitHub Pages or web server:

1. **Create releases on GitHub**
   ```bash
   git tag v4.0.1
   git push origin v4.0.1
   ```

2. **Create AutoFuse.app.zip release artifact**
   ```bash
   cd ~/Applications/AutoFuse.app/..
   zip -r AutoFuse.app.zip AutoFuse.app
   # Upload to GitHub Releases
   ```

3. **Update appcast.xml** with release information:
   - `sparkle:version` - Internal version number
   - `sparkle:shortVersionString` - User-visible version (4.0, 4.0.1, etc.)
   - `enclosure url` - Download link to AutoFuse.app.zip
   - `length` - File size in bytes

4. **Publish appcast.xml** to GitHub Pages:
   ```bash
   git add appcast.xml
   git commit -m "chore: update appcast for v4.0.1"
   git push
   ```
   Available at: `https://raw.githubusercontent.com/Fasen24-AI/autofuse/main/appcast.xml`

## Public Key (for Signed Releases)

For secure updates, sign your releases with a private EdDSA key and add the public key to Info.plist:

### Generate Key Pair

```bash
# Generate private key (save securely, never commit)
openssl genpkey -algorithm ed25519 -out autofuse_private.key

# Export public key
openssl pkey -in autofuse_private.key -pubout -out autofuse_public.key
```

### Add Public Key to Info.plist

Extract the base64-encoded public key and add to Info.plist:

```xml
<key>SUPublicEDKey</key>
<string>BASE64_ENCODED_PUBLIC_KEY_HERE</string>
```

### Sign Releases

When creating new releases, sign the .app.zip file:

```bash
# Install Sparkle CLI tools
brew install sparkle

# Generate signature
generate_keys --public-key-output-path autofuse_public.key \
              --private-key-output-path autofuse_private.key

sign_update AutoFuse.app.zip autofuse_private.key
```

Include the signature in appcast.xml's `<sparkle:dsaSignature>` tag.

## Testing Updates

### Check for Updates Menu

When Sparkle is installed, a "Check for Updates..." menu item appears in the AutoFuse menu bar app.

Click to manually check for updates. Sparkle will:
1. Fetch the appcast.xml feed
2. Compare current version with latest release
3. Download and install if newer version available
4. Relaunch AutoFuse

### Disable for Testing

To test without internet connectivity:

1. Edit Info.plist temporarily:
   ```xml
   <key>SUFeedURL</key>
   <string>file:///tmp/test-appcast.xml</string>
   ```

2. Create test appcast with higher version number

3. Run AutoFuse and test "Check for Updates..."

## Troubleshooting

### Sparkle Not Detected

If Sparkle is installed but not bundled:
1. Verify installation: `ls /opt/homebrew/opt/sparkle/` or `ls /usr/local/opt/sparkle/`
2. Clean rebuild: `rm build.sh && bash build.sh`
3. Check Console.app for Sparkle errors

### No Update Menu Item

If "Check for Updates..." doesn't appear:
1. Rebuild with Sparkle installed
2. Check that Sparkle.framework is in `Contents/Frameworks/`
3. Verify Info.plist has SUFeedURL key

### Updates Not Showing

If menu works but no updates appear:
1. Check appcast.xml is accessible at SUFeedURL
2. Verify `sparkle:shortVersionString` in appcast is higher than current version
3. Check macOS Security & Privacy settings (may block unsigned binaries)

## References

- Sparkle Framework: https://sparkle-project.org/
- Appcast Format: https://sparkle-project.org/documentation/appcast-format/
- EdDSA Signing: https://sparkle-project.org/documentation/eddsa/
