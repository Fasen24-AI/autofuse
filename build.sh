#!/bin/bash
# Build AutoFuse.app v4
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/AutoFuse.app"
BACKUP="$HOME/Applications/AutoFuse.app.bak"
VERSION="4.1"  # keep in sync with CFBundleVersion in the Info.plist below

echo "=== Building AutoFuse v4 ==="

# Build MCP server TypeScript — do NOT swallow errors, we want visible
# feedback if tsc fails (previous `> /dev/null 2>&1` masked npm/tsc failures
# and left the bundle without an Info.plist because `set -e` killed the
# script before reaching the plist generation below).
echo "Building MCP server..."
cd "$DIR/mcp-server"
if ! npm run build; then
    echo "WARNING: MCP server build failed — continuing without updated MCP bundle"
    # Non-fatal: the menu-bar app is independently useful without the MCP.
    MCP_BUILD_FAILED=1
fi
if [ ! -f "dist/index.js" ]; then
    echo "WARNING: dist/index.js missing — MCP bundle skipped"
    MCP_BUILD_FAILED=1
fi
cd "$DIR"
[ -z "${MCP_BUILD_FAILED:-}" ] && echo "✓ MCP server built"

# Compile — add UserNotifications and SystemConfiguration frameworks
# Conditionally add Sparkle framework if present
SPARKLE_FLAGS=""
if [ -d "/opt/homebrew/opt/sparkle/Sparkle.framework" ]; then
    SPARKLE_FLAGS="-framework Sparkle -F/opt/homebrew/opt/sparkle"
elif [ -d "/usr/local/opt/sparkle/Sparkle.framework" ]; then
    SPARKLE_FLAGS="-framework Sparkle -F/usr/local/opt/sparkle"
fi

clang -fobjc-arc -framework Cocoa -framework UserNotifications -framework ServiceManagement -framework SystemConfiguration $SPARKLE_FLAGS \
    -o "$DIR/AutoFuse" \
    "$DIR/main.m"

echo "✓ Compiled ($(wc -c < "$DIR/AutoFuse" | tr -d ' ') bytes)"

# Backup old app
if [ -d "$APP" ]; then
    rm -rf "$BACKUP"
    mv "$APP" "$BACKUP"
    echo "✓ Backed up old app"
fi

# Create .app bundle
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Bundle Sparkle framework if available
if [ -d "/opt/homebrew/opt/sparkle/Sparkle.framework" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -r "/opt/homebrew/opt/sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
    echo "✓ Bundled Sparkle framework"
elif [ -d "/usr/local/opt/sparkle/Sparkle.framework" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -r "/usr/local/opt/sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
    echo "✓ Bundled Sparkle framework"
fi

cp "$DIR/AutoFuse" "$APP/Contents/MacOS/"
cp "$DIR/mount.sh"         "$APP/Contents/Resources/"
cp "$DIR/discover.sh"      "$APP/Contents/Resources/"
cp "$DIR/config.json"      "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/mount.sh"
chmod +x "$APP/Contents/Resources/discover.sh"

# Write Info.plist FIRST so the bundle is launchable even if later steps
# (MCP copy, npm install) fail. Previously this lived at the end of the
# script — a stalled `npm install` on flaky WiFi would kill the script
# before Info.plist was created, leaving an unlaunchable .app.
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AutoFuse</string>
    <key>CFBundleIdentifier</key>
    <string>com.fasen24.autofuse</string>
    <key>CFBundleVersion</key>
    <string>4.1</string>
    <key>CFBundleShortVersionString</key>
    <string>4.1</string>
    <key>CFBundleExecutable</key>
    <string>AutoFuse</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://fasen24-ai.github.io/autofuse/appcast.xml</string>
    <key>SUEnableInstallerLauncherService</key>
    <true/>
</dict>
</plist>
PLIST

# Bundle MCP server — gated so upstream build failures don't break the app.
if [ -z "${MCP_BUILD_FAILED:-}" ] && [ -f "$DIR/mcp-server/dist/index.js" ]; then
    echo "Bundling MCP server..."
    mkdir -p "$APP/Contents/Resources/mcp"
    cp "$DIR/mcp-server/dist"/*.js "$APP/Contents/Resources/mcp/" 2>/dev/null || true
    cp "$DIR/mcp-server/dist"/*.map "$APP/Contents/Resources/mcp/" 2>/dev/null || true
    cp "$DIR/mcp-server/package.json" "$APP/Contents/Resources/mcp/" 2>/dev/null || true

    # npm install is the slowest step and the most network-dependent.
    # Use a 60s hard timeout so a flaky WiFi doesn't stall the build
    # indefinitely (happened in field testing — university intranet).
    (cd "$APP/Contents/Resources/mcp" && perl -e 'alarm 60; exec @ARGV' \
        npm install --production --silent 2>/dev/null) || \
        echo "  (MCP dependency install skipped — run 'npm install' manually if needed)"
    echo "✓ MCP bundled"
else
    echo "⚠ MCP bundle skipped (build failed or dist missing)"
fi

# Also install config to ~/.config for user editing
# New path: ~/.config/autofuse/
mkdir -p "$HOME/.config/autofuse"
if [ ! -f "$HOME/.config/autofuse/config.json" ]; then
    # Migrate from old path if it exists
    if [ -f "$HOME/.config/workstationmount/config.json" ]; then
        cp "$HOME/.config/workstationmount/config.json" "$HOME/.config/autofuse/config.json"
        chmod 600 "$HOME/.config/autofuse/config.json"
        echo "✓ Migrated config from ~/.config/workstationmount/ to ~/.config/autofuse/config.json (mode 0600)"
    else
        cp "$DIR/config.json" "$HOME/.config/autofuse/config.json"
        chmod 600 "$HOME/.config/autofuse/config.json"
        echo "✓ Installed config to ~/.config/autofuse/config.json (mode 0600)"
    fi
else
    echo "✓ User config already exists at ~/.config/autofuse/config.json"
fi

# Distributable, Sparkle-signable archive. release.yml uploads AutoFuse-*.zip
# to the GitHub Release; appcast.xml references this name. ditto preserves the
# .app bundle structure (use this, not `zip`, for macOS app archives).
ZIP="$DIR/AutoFuse-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ Archive: $ZIP ($(wc -c < "$ZIP" | tr -d ' ') bytes)"

echo "✓ Built $APP"
echo ""
echo "Binary: $(wc -c < "$APP/Contents/MacOS/AutoFuse" | tr -d ' ') bytes"
echo "Config: ~/.config/autofuse/config.json"
echo ""
echo "To add a new workstation, edit the config and add an entry to 'workstations'."
echo "To launch: open $APP"
