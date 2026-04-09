# Deploy-ClaudeCode.ps1

Automated deployment of Claude Code, Cowork, and plugins on Windows 10/11 + WSL2.

Built for **G Mining Services (CAGM)** engineering workstations. Designed to be consumed by AI agents or run manually by IT admins.

## Quick Start

```powershell
# Full deployment (run as Administrator)
.\Deploy-ClaudeCode.ps1

# Dry run (simulation, no changes)
.\Deploy-ClaudeCode.ps1 -DryRun

# With corporate proxy + plugin from network share
.\Deploy-ClaudeCode.ps1 -ProxyUrl "http://proxy:8080" -PluginSourcePath "\\server\share\plugin"

# Admin-only mode (managed-settings, WSL features, scheduled task)
.\Deploy-ClaudeCode.ps1 -AdminOnly
```

## Prerequisites

- Windows 10 version 1903+ or Windows 11
- PowerShell 5.1+ (7+ recommended)
- Local administrator rights
- Network access to `claude.ai`

## What It Does

| Step | Component | Description |
|:----:|-----------|-------------|
| 0 | Pre-flight | Admin check, Windows version, network connectivity, Git auto-install |
| 1 | WSL2 | Virtual Machine Platform + Ubuntu distro (unattended, resume after reboot) |
| 2 | CC CLI (WSL) | Claude Code native binary in WSL2 |
| 3 | CC CLI (Win) | Claude Code native binary on Windows |
| 4 | Desktop | Claude Desktop / Cowork (MSIX via winget) |
| 5 | VS Code | Extensions: claude-code + remote-wsl (auto-installs VS Code if missing) |
| 6 | Settings | Managed-settings.json in Program Files (centralized config) |
| 7 | Plugin | Deploy plugin from network share or local path |
| 8 | Shell | Autocompletion for PowerShell + Bash/Zsh in WSL2 |
| 9 | Updates | Scheduled task for automatic weekly updates |
| 10 | Validation | Final report (JSON) with all component statuses |

## Features

- **Resume after reboot**: If WSL2 activation requires a restart, the script auto-resumes via RunOnce registry
- **Dry run mode**: Full simulation without making changes
- **Proxy support**: Corporate HTTP/HTTPS proxy passthrough
- **Admin/User split**: `-AdminOnly` for IT admins, user-space steps run without elevation
- **Force reinstall**: `-ForceReinstall` to re-deploy even if components exist
- **Pre-flight inventory**: JSON report of machine state before deployment
- **Validation report**: JSON report of deployment results

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-PluginSourcePath` | string | UNC or local path to plugin folder |
| `-ManagedSettingsPath` | string | Path to custom managed-settings.json |
| `-ProxyUrl` | string | Corporate HTTP proxy URL |
| `-SkipRebootCheck` | switch | Ignore pending reboot check |
| `-ForceReinstall` | switch | Force reinstallation of all components |
| `-AdminOnly` | switch | Only run admin-required steps |
| `-WSLUser` | string | WSL username to create (default: `claude`) |
| `-DryRun` | switch | Simulate without making changes |

## Documentation

- [Guide-Deploiement-ClaudeCode-CAGM.docx](Guide-Deploiement-ClaudeCode-CAGM.docx) - Full deployment guide (French)
- [Runbook-Deploiement-ClaudeCode-CAGM.xlsx](Runbook-Deploiement-ClaudeCode-CAGM.xlsx) - Step-by-step runbook

## For AI Agents

To consume this script programmatically:

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/seb155/cc-setup/main/Deploy-ClaudeCode.ps1 -o Deploy-ClaudeCode.ps1

# Run in dry-run mode first
powershell -ExecutionPolicy Bypass -File Deploy-ClaudeCode.ps1 -DryRun

# Full deployment
powershell -ExecutionPolicy Bypass -File Deploy-ClaudeCode.ps1
```

## License

Internal use - G Mining Services (CAGM).

---

*v3.0.0 | April 2026 | Author: Sebastien Gagnon*
