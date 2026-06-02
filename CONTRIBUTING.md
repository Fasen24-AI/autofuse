# Contributing to AutoFuse

Thank you for your interest in AutoFuse! We welcome contributions of all kinds.

## Reporting Bugs

Found a bug? Please [create a GitHub Issue](https://github.com/Fasen24-AI/autofuse/issues/new?template=bug_report.md) with:

- **macOS version** (e.g., 14.2)
- **AutoFuse version** (check `autofuse version` or menu bar icon)
- **FUSE backend** (FUSE-T or macFUSE)
- **Steps to reproduce** the issue
- **Expected vs actual behavior**
- **Logs** from `~/.config/autofuse/autofuse.log` (attach if relevant)

## Suggesting Features

Have an idea? [Create a Feature Request Issue](https://github.com/Fasen24-AI/autofuse/issues/new?template=feature_request.md) describing:

- What problem it solves
- How you'd use it
- Any alternative approaches you've considered

## Development Setup

### Prerequisites

- macOS 13.0+
- Xcode Command Line Tools: `xcode-select --install`
- FUSE-T or macFUSE installed
- Homebrew (optional, for dependencies)

### Clone and Build

```bash
git clone https://github.com/Fasen24-AI/autofuse.git
cd autofuse

# Compile the app
clang -fobjc-arc \
  -framework Cocoa \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework SystemConfiguration \
  -o AutoFuse main.m

# Run tests
bash test.sh

# Build the .app bundle (and release zip)
bash build.sh
```

### Code Style

Please follow the existing Objective-C conventions in `main.m`:

- Use `NS` prefixes for Foundation types
- Use `@autoreleasepool` for memory management
- Follow Apple's Cocoa naming conventions
- Keep methods focused and under 50 lines when possible
- Comment public methods and complex logic

### File Organization

- `main.m` — Core menu bar app and UI (single-file Objective-C, ARC)
- `mount.sh` — SSHFS mounting logic, endpoint cache, host-key pinning
- `discover.sh` — Network scanning and auto-discovery
- `cli/autofuse` — Command-line tool
- `mcp-server/` — Model Context Protocol server (TypeScript)
- `test.sh` — Test suite

### Architecture Conventions

A few invariants keep the three layers (app, engine, MCP server) consistent:

- **The bash engine (`mount.sh`) is the source of truth.** The app and the MCP
  server both shell out to it. New mount behavior goes into bash first; the UI
  and MCP layer wrap it.
- **Exit-code-as-signal.** `mount.sh` may exit non-zero while still printing a
  meaningful status line on stdout. Callers preserve both — don't convert a
  non-zero exit into a thrown error if there's a usable status line.
- **Engine output strings are a stable API.** Results are stable strings
  (`mounted_lan:/path`, `failed:<reason>`, `host|disk|status`). Changing a
  format string is a breaking change — grep `mcp-server/` and `test.sh` for
  consumers first. `autofuse json [...]` re-shapes these as stable JSON.
- **Never interpolate untrusted input into an interpreter.** Remote-host output
  and user config are passed via `argv` (`python3 -c '…' "$value"`), never spliced
  into a shell or Python source string.
- **Energy discipline.** The app detects mounts with `getmntinfo()` (no
  subprocesses) on an adaptive poll cadence. Avoid per-poll subprocess or
  network work; hook expensive checks to events (menu open, wake, network change).

## Pull Request Process

1. **Fork the repo** and create a feature branch: `git checkout -b feature/your-feature`
2. **Make your changes** following the code style above
3. **Test locally**: `bash test.sh`
4. **Commit with clear messages**: 
   ```
   feat: add support for custom mount options
   
   Allows users to specify custom SSH options via the preferences window.
   ```
5. **Push and create a PR** with:
   - Clear description of what changed and why
   - Link to any related issues
   - Evidence that tests pass

### Commit Message Format

Use conventional commits:
- `feat:` new feature
- `fix:` bug fix
- `refactor:` code refactoring
- `docs:` documentation
- `test:` test additions/changes
- `perf:` performance improvement

## Testing

All pull requests must pass the test suite:

```bash
bash test.sh
```

The test suite covers:
- FUSE-T and macFUSE backends
- SSH key generation and validation
- Network discovery
- Mount/unmount operations
- Wake-on-LAN functionality
- Configuration import/export
- CLI command parsing

## Security

Found a security issue? **Do not** create a public issue. Instead:
1. Use [GitHub private vulnerability reporting](https://github.com/Fasen24-AI/autofuse/security/advisories/new)
2. Allow 72 hours for response before public disclosure
3. See [SECURITY.md](SECURITY.md) for full policy

## Questions?

- Check the [README](README.md) and [docs](docs/) folder
- Review existing [Issues](https://github.com/Fasen24-AI/autofuse/issues)
- Open a [Discussion](https://github.com/Fasen24-AI/autofuse/discussions)

Thank you for contributing to AutoFuse!
