#!/bin/bash

# AutoFuse MCP Server Installer
# Automatically installs and configures the MCP server for Claude Desktop and Claude Code

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PACKAGE_NAME="@autofuse/mcp-server"
BIN_NAME="autofuse-mcp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect OS
OS_TYPE=$(uname -s)
if [ "$OS_TYPE" = "Darwin" ]; then
    CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"
else
    # Linux/Windows (Git Bash)
    CLAUDE_CONFIG_DIR="$HOME/.config/Claude"
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Step 1: Build the package
log_info "Building AutoFuse MCP server..."
cd "$SCRIPT_DIR"
npm run build

# Step 2: Link the package globally (optional but useful)
log_info "Installing package globally..."
npm install -g "$SCRIPT_DIR"

# Step 3: Find the bin path
BIN_PATH=$(npm config get prefix)/bin/$BIN_NAME
if [ ! -f "$BIN_PATH" ]; then
    log_warning "Binary not found at $BIN_PATH"
    # Try to find the built executable
    BIN_PATH="$SCRIPT_DIR/dist/index.js"
    if [ ! -f "$BIN_PATH" ]; then
        log_error "Could not find executable"
        exit 1
    fi
    log_info "Using: $BIN_PATH"
fi

log_info "Binary location: $BIN_PATH"

# Step 4: Create Claude config directory if it doesn't exist
if [ ! -d "$CLAUDE_CONFIG_DIR" ]; then
    log_info "Creating Claude config directory: $CLAUDE_CONFIG_DIR"
    mkdir -p "$CLAUDE_CONFIG_DIR"
fi

# Step 5: Update or create claude_desktop_config.json
CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

if [ -f "$CONFIG_FILE" ]; then
    log_info "Updating existing configuration: $CONFIG_FILE"
    # Use Python to safely merge JSON
    python3 << PYTHON_END
import json
import sys

config_file = "$CONFIG_FILE"
bin_path = "$BIN_PATH"

try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except:
    config = {"mcpServers": {}}

# Add autofuse-mcp server configuration
config["mcpServers"] = config.get("mcpServers", {})
config["mcpServers"]["autofuse-mcp"] = {
    "command": "node",
    "args": ["$BIN_PATH"]
}

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Configuration updated: {config_file}")
PYTHON_END
else
    log_info "Creating new configuration: $CONFIG_FILE"
    cat > "$CONFIG_FILE" << JSON_EOF
{
  "mcpServers": {
    "autofuse-mcp": {
      "command": "node",
      "args": ["$BIN_PATH"]
    }
  }
}
JSON_EOF
fi

log_info "Configuration saved to: $CONFIG_FILE"

# Step 6: Verification
log_info "Verifying installation..."
if [ -f "$CONFIG_FILE" ] && grep -q "autofuse-mcp" "$CONFIG_FILE"; then
    log_info "AutoFuse MCP server successfully installed!"
    log_info "Configuration file: $CONFIG_FILE"
    log_info ""
    log_info "Next steps:"
    log_info "1. Restart Claude Desktop or Claude Code"
    log_info "2. The AutoFuse MCP server will be available as a tool"
    log_info ""
    log_info "Configuration preview:"
    cat "$CONFIG_FILE"
else
    log_error "Installation verification failed"
    exit 1
fi
