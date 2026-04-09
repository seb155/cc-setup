# Deploy-ClaudeCode.ps1

Automated deployment of Claude Code, Cowork, and plugins on Windows 10/11 + WSL2.

Built for **G Mining Services (CAGM)** engineering workstations. Designed to be consumed by AI agents or run manually by IT admins.

## Quick Start

```powershell
# Interactive menu (recommended)
.\Deploy-ClaudeCode.ps1

# Standard user: Desktop + Cowork + GMS plugin
.\Deploy-ClaudeCode.ps1 -Profile Standard -PluginSourcePath "\\server\share\plugin"

# Developer: Full stack + WSL2 + VS Code + ATLAS plugin + CShip
.\Deploy-ClaudeCode.ps1 -Profile Developer -GithubToken "ghp_xxx"

# IT Admin: prepare workstation silently
.\Deploy-ClaudeCode.ps1 -Profile Admin

# Dry run (simulation, no changes)
.\Deploy-ClaudeCode.ps1 -DryRun
```

## Profiles

| Profile | Target | What Gets Installed |
|---------|--------|---------------------|
| **Standard** | Engineers, managers, admin staff | Desktop + Cowork + GMS plugin + auto-updates |
| **Developer** | I&C, EL, coders, power users | Standard + WSL2 + VS Code + CLI + ATLAS plugin + CShip |
| **Admin** | IT administrators | managed-settings + WSL features + scheduled task |
| **Custom** | Special cases | Interactive step selection |

## Prerequisites

- Windows 10 version 1903+ or Windows 11
- PowerShell 5.1+ (7+ recommended)
- Local administrator rights
- Network access to `claude.ai`

## All Steps

| # | Component | Standard | Developer | Admin |
|:-:|-----------|:--------:|:---------:|:-----:|
| 0 | Pre-flight (admin, network, Git) | ✅ | ✅ | ✅ |
| 1 | WSL2 (VMP + Ubuntu distro) | ✅ VMP | ✅ Full | ✅ |
| 2 | CC CLI (WSL2) | | ✅ | |
| 3 | CC CLI (Windows) | | ✅ | |
| 4 | Claude Desktop / Cowork (MSIX) | ✅ | ✅ | |
| 5 | VS Code + extensions + shortcuts | | ✅ | |
| 6 | managed-settings.json + registry | ✅ | ✅ | ✅ |
| 7 | Plugin GMS (network share copy) | ✅ | | |
| 8 | Plugin ATLAS (GitHub marketplace) | | ✅ | |
| 9 | Shell autocompletion (PS + Bash) | ✅ | ✅ | |
| 10 | CShip status line (binary + config) | | ✅ | |
| 11 | Auto-update scheduled task | ✅ | ✅ | ✅ |
| 12 | Validation report (JSON) | ✅ | ✅ | ✅ |
| 13 | Windows Terminal (ATLAS profile + shortcut) | | ✅ | |

## Features

- **Auto-elevation UAC**: Automatically prompts for admin rights when needed
- **Interactive menu**: Always displayed, profiles pre-selectable via `-Profile`
- **Resume after reboot**: WSL2 activation auto-resumes via RunOnce registry
- **Dry run mode**: Full simulation without making changes
- **Proxy support**: Corporate HTTP/HTTPS proxy passthrough
- **ATLAS marketplace**: Auto-registers `seb155/atlas-plugin` with GITHUB_TOKEN
- **CShip status line**: 3-row enriched status bar (model, context %, git, rate limits)
- **Smart WSL user**: Defaults to Windows username (lowercased)
- **Force reinstall**: `-ForceReinstall` to re-deploy even if components exist
- **Pre-flight inventory**: JSON report of machine state before deployment
- **Validation report**: JSON report of deployment results

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Profile` | string | `Standard`, `Developer`, `Admin`, or `Custom` |
| `-PluginSourcePath` | string | UNC or local path to GMS plugin folder |
| `-GithubToken` | string | GitHub PAT for ATLAS marketplace (Developer profile) |
| `-ManagedSettingsPath` | string | Path to custom managed-settings.json |
| `-ProxyUrl` | string | Corporate HTTP proxy URL |
| `-SkipRebootCheck` | switch | Ignore pending reboot check |
| `-ForceReinstall` | switch | Force reinstallation of all components |
| `-AdminOnly` | switch | Legacy alias for `-Profile Admin` |
| `-WSLUser` | string | WSL username (default: Windows username, lowered) |
| `-DryRun` | switch | Simulate without making changes |

## Documentation

- [Guide-Deploiement-ClaudeCode-CAGM.docx](Guide-Deploiement-ClaudeCode-CAGM.docx) - Full deployment guide (French)
- [Runbook-Deploiement-ClaudeCode-CAGM.xlsx](Runbook-Deploiement-ClaudeCode-CAGM.xlsx) - Step-by-step runbook

## For AI Agents

```bash
# Download
curl -fsSL https://raw.githubusercontent.com/seb155/cc-setup/main/Deploy-ClaudeCode.ps1 -o Deploy-ClaudeCode.ps1

# Dry run
powershell -ExecutionPolicy Bypass -File Deploy-ClaudeCode.ps1 -DryRun

# Deploy for developer
powershell -ExecutionPolicy Bypass -File Deploy-ClaudeCode.ps1 -Profile Developer -GithubToken "$GITHUB_TOKEN"

# Deploy for standard user with plugin
powershell -ExecutionPolicy Bypass -File Deploy-ClaudeCode.ps1 -Profile Standard -PluginSourcePath "C:\Deploy\genie-gms"
```

## License

Internal use - G Mining Services (CAGM).

---

*v4.0.0 | April 2026 | Author: Sebastien Gagnon*
