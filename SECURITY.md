# Security Policy

## Supported Versions

| Version | Status      | Support Until |
|---------|-------------|----------------|
| 4.x     | Supported   | Current        |
| 3.x     | EOL         | 2026-01-01    |

Only the latest major version (4.x) receives security updates.

## Reporting a Vulnerability

**Do not** create a public GitHub issue for security vulnerabilities.

Instead:
1. Use [GitHub private vulnerability reporting](https://github.com/Fasen24-AI/autofuse/security/advisories/new) with:
   - Vulnerability description
   - Steps to reproduce
   - Affected versions
   - Recommended fix (if you have one)

2. Allow **72 hours** for a response before public disclosure

## Security Best Practices

### For Users

- **SSH Keys:** AutoFuse only supports key-based authentication. Never store passwords.
- **Permissions:** Config files are created with mode `0600` (readable only by you).
- **Network:** SSH tunnel encrypts all data in transit.
- **Logging:** Logs don't contain passwords or sensitive data.

### For Developers

- **No Hardcoded Secrets:** Never commit API keys, certificates, or credentials.
- **Config Validation:** All user input is validated before use.
- **SSH Restrictions:** AutoFuse uses SSH with strict key checking enabled.
- **Error Messages:** Errors don't leak paths, keys, or system details.

## MCP Server Threat Model

The MCP server is **single-tenant by design**: it runs locally, as your own
user, for your own MCP client (Claude Desktop, Claude Code, etc.). It is not
a network service and must never be exposed to untrusted clients.

- **`run_local_shell` and `run_remote_shell` are intentionally unrestricted.**
  They exist so an AI agent can operate your machines on your behalf — the
  same capability you already have in a terminal. The permission layer is the
  MCP client: Claude asks for per-tool approval before execution. If your
  client auto-approves tools, you are accepting shell access for the agent.
- **Remote commands run over host-key-verified SSH** (pinned SHA-256
  fingerprints, dedicated `known_hosts`) — a DNS/ARP hijack cannot redirect
  them to an unverified host.
- **Untrusted input is never interpolated** into shell or Python source;
  remote-host output is passed via `argv`.
- **The config tool never returns key material** — only the SSH key path.
- Filesystem tools (`reveal_in_finder`, etc.) are confined to AutoFuse mount
  points via `realpath` containment checks.

Do not install the MCP server on multi-user machines where other local users
can reach your MCP client session.

## Scope

### In Scope

- Remote code execution vulnerabilities
- Privilege escalation
- Credential exposure (hardcoded secrets, logs)
- Cryptographic weaknesses
- Data loss or corruption
- Denial of service

### Out of Scope

- Issues in dependencies (report to upstream maintainers)
- macOS or FUSE-T vulnerabilities (report to Apple)
- Social engineering or phishing
- Physical security
- Theoretical attacks without proof of concept

## Disclosure Timeline

1. **Day 1:** You report the issue
2. **Day 3:** We acknowledge receipt and provide timeline
3. **Day 7-30:** We develop and test fix (depending on severity)
4. **Day 31:** We release patched version
5. **Day 32:** Public disclosure (CVE if applicable)

### Critical Issues (CVSS 9-10)

- Fixed and released within **48 hours**
- Public disclosure after release

### High Issues (CVSS 7-8.9)

- Fixed and released within **7 days**
- Public disclosure after release

### Medium Issues (CVSS 4-6.9)

- Fixed in next scheduled release
- Can be disclosed after 30 days

### Low Issues (CVSS 0-3.9)

- Fixed when convenient
- Can be disclosed immediately

## Acknowledgments

We appreciate responsible disclosure. Contributors to security fixes will be credited in the release notes (unless you prefer anonymity).

## Additional Resources

- [OWASP Secure Coding Practices](https://cheatsheetseries.owasp.org/)
- [Apple Security Guidelines](https://developer.apple.com/security/)
- [OpenSSH Security](https://man.openbsd.org/sshd_config)

---

Last updated: 2026-04-21
