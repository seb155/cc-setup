<#
.SYNOPSIS
    Deploy-ClaudeCode.ps1 - Deploiement automatise de Claude Code, Cowork et plugins pour G Mining Services

.DESCRIPTION
    Script POC pour deployer l'environnement Claude complet sur les postes Windows 10/11 avec WSL2.
    Composantes deployees :
      0. Pre-flight inventory + verifications preliminaires
      1. WSL2 (Virtual Machine Platform + distro Ubuntu)
      2. Claude Code CLI (natif) dans WSL2
      3. Claude Code CLI (natif) sur Windows
      4. Claude Desktop / Cowork (MSIX) sur Windows
      5. Extension VS Code (Claude Code + WSL Remote) + auto-install VS Code/Git
      6. Configuration centralisee (managed-settings.json)
      7. Plugin depuis partage reseau ou chemin local
      8. Autocompletion shell (PowerShell + Bash/Zsh dans WSL2)
      9. Tache planifiee de mise a jour automatique
     10. Validation finale + rapport JSON

    Fonctionnalites v2.0 :
      - Resume automatique apres reboot (RunOnce registry)
      - Auto-install Git et VS Code via winget
      - Pre-check extensions (skip si deja installees)
      - Protection settings utilisateur (merge, jamais overwrite)
      - Support proxy HTTP/HTTPS (-ProxyUrl)
      - Pre-flight inventory JSON

.PARAMETER PluginSourcePath
    Chemin UNC ou local vers le dossier du plugin (ex: \\server\share\genie-gms-assistant)

.PARAMETER ManagedSettingsPath
    Chemin optionnel vers un managed-settings.json personnalise a deployer

.PARAMETER SkipRebootCheck
    Ignore la verification de redemarrage necessaire pour WSL2

.PARAMETER ForceReinstall
    Force la reinstallation meme si les composantes sont deja presentes

.PARAMETER ProxyUrl
    URL du proxy HTTP corporatif (ex: http://proxy.gmining.com:8080)

.PARAMETER AdminOnly
    Execute seulement les etapes admin (managed-settings, WSL features, scheduled task).
    Les etapes user-space (CLI, extensions, bashrc) sont ignorees.

.PARAMETER WSLUser
    Nom d'utilisateur a creer dans WSL (defaut: claude). Utilise pour l'installation unattended.

.PARAMETER DryRun
    Affiche les actions sans les executer

.NOTES
    Auteur  : Sebastien Gagnon - G Mining Services (CAGM)
    Version : 3.0.0
    Date    : 2026-04-08
    Licence : Usage interne CAGM uniquement

    Prerequis pour l'execution :
      - Windows 10 version 1903+ ou Windows 11
      - PowerShell 5.1+ (ou 7+)
      - Droits administrateur locaux
      - Acces reseau au partage du plugin (si applicable)

    Usage :
      # Deploiement complet
      .\Deploy-ClaudeCode.ps1 -PluginSourcePath "\\srv-files\Tools\genie-gms-assistant"

      # Mode simulation (DryRun complet sans arreter)
      .\Deploy-ClaudeCode.ps1 -DryRun

      # Avec proxy corporatif
      .\Deploy-ClaudeCode.ps1 -ProxyUrl "http://proxy.gmining.com:8080" -PluginSourcePath "C:\Temp\genie-gms-assistant"

      # Forcer la reinstallation (binaires seulement, pas les settings)
      .\Deploy-ClaudeCode.ps1 -ForceReinstall -PluginSourcePath "C:\Temp\genie-gms-assistant"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PluginSourcePath = "",

    [Parameter(Mandatory = $false)]
    [string]$ManagedSettingsPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ProxyUrl = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipRebootCheck,

    [Parameter(Mandatory = $false)]
    [switch]$ForceReinstall,

    [Parameter(Mandatory = $false)]
    [switch]$AdminOnly,

    [Parameter(Mandatory = $false)]
    [string]$WSLUser = "claude",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

# ============================================================================
# CONFIGURATION - Modifier ces valeurs selon votre environnement
# ============================================================================

$Config = @{
    # Canaux et versions
    ClaudeCodeChannel       = "stable"                     # "stable" ou "latest"
    AutoUpdatesChannel      = "stable"                     # Canal de mise a jour auto

    # VS Code extensions a installer
    VSCodeExtensions        = @(
        "anthropic.claude-code"                            # Claude Code
        "ms-vscode-remote.remote-wsl"                      # WSL Remote
    )

    # WSL distro
    WSLDistro               = "Ubuntu-22.04"

    # Chemins (IMPORTANT: ProgramData est DEPRECIE depuis v2.1.75, utiliser Program Files)
    LogFile                 = "$env:LOCALAPPDATA\ClaudeCode\deploy.log"
    ManagedSettingsWin      = "$env:ProgramFiles\ClaudeCode\managed-settings.json"
    ManagedSettingsLegacy   = "$env:ProgramData\ClaudeCode\managed-settings.json"
    UserSettingsDir         = "$env:USERPROFILE\.claude"
    PluginDeployDir         = "$env:USERPROFILE\.claude\plugins"

    # Mise a jour planifiee
    UpdateTaskName          = "ClaudeCode-AutoUpdate"
    UpdateSchedule          = "Weekly"                      # "Daily" ou "Weekly"
    UpdateTime              = "06:00"                       # Heure locale
}

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "STEP")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "INFO"    { "[i]" }
        "WARN"    { "[!]" }
        "ERROR"   { "[X]" }
        "SUCCESS" { "[+]" }
        "STEP"    { "[>]" }
    }

    $logLine = "[$timestamp] $prefix $Message"

    # Console output avec couleurs
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "STEP"    { "White" }
    }
    Write-Host $logLine -ForegroundColor $color

    # Fichier log
    $logDir = Split-Path $Config.LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $Config.LogFile -Value $logLine -Encoding UTF8
}

function Test-AdminPrivileges {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RebootPending {
    $rebootKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($key in $rebootKeys) {
        if (Test-Path $key) { return $true }
    }
    return $false
}

function Invoke-WithDryRun {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    if ($DryRun) {
        Write-Log "[DRY RUN] $Description" -Level "WARN"
        return
    }

    try {
        $null = & $Action
    }
    catch {
        Write-Log "ECHEC: $Description - $_" -Level "ERROR"
        Write-Log "L'etape a echoue mais le deploiement continue." -Level "WARN"
    }
}

# ============================================================================
# FONCTIONS DE RESUME APRES REBOOT
# ============================================================================

$ResumeRegistryPath = "HKCU:\Software\CAGM\ClaudeCodeDeploy"

function Get-ResumeStep {
    try {
        if (Test-Path $ResumeRegistryPath) {
            $val = Get-ItemProperty -Path $ResumeRegistryPath -Name "ResumeStep" -ErrorAction SilentlyContinue
            if ($val) { return [int]$val.ResumeStep }
        }
    }
    catch { }
    return 0
}

function Save-ResumeState {
    param([int]$StepIndex)
    try {
        if (-not (Test-Path $ResumeRegistryPath)) {
            New-Item -Path $ResumeRegistryPath -Force | Out-Null
        }
        Set-ItemProperty -Path $ResumeRegistryPath -Name "ResumeStep" -Value $StepIndex
        Set-ItemProperty -Path $ResumeRegistryPath -Name "ScriptPath" -Value $PSCommandPath
        Set-ItemProperty -Path $ResumeRegistryPath -Name "SavedAt" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

        # Reconstruire les arguments originaux
        $argString = ""
        if ($PluginSourcePath) { $argString += " -PluginSourcePath `"$PluginSourcePath`"" }
        if ($ManagedSettingsPath) { $argString += " -ManagedSettingsPath `"$ManagedSettingsPath`"" }
        if ($ForceReinstall) { $argString += " -ForceReinstall" }
        if ($ProxyUrl) { $argString += " -ProxyUrl `"$ProxyUrl`"" }
        Set-ItemProperty -Path $ResumeRegistryPath -Name "OriginalArgs" -Value $argString.Trim()

        # Creer entree RunOnce pour relancer apres reboot
        $runOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        $resumeCmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`"$argString"
        Set-ItemProperty -Path $runOnceKey -Name "ClaudeCodeDeploy" -Value $resumeCmd
        Write-Log "Resume automatique configure. Le script reprendra apres le reboot." -Level "SUCCESS"
    }
    catch {
        Write-Log "Impossible de configurer le resume automatique: $_" -Level "WARN"
        Write-Log "Apres le reboot, relancez manuellement: $PSCommandPath$argString" -Level "INFO"
    }
}

function Clear-ResumeState {
    try {
        if (Test-Path $ResumeRegistryPath) {
            Remove-Item -Path $ResumeRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

# ============================================================================
# PRE-FLIGHT INVENTORY
# ============================================================================

function Write-PreFlightInventory {
    Write-Log "Inventaire pre-deploiement du poste..." -Level "INFO"

    $inventory = @{
        Timestamp    = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        Computer     = $env:COMPUTERNAME
        User         = $env:USERNAME
        OS           = @{
            Version  = [System.Environment]::OSVersion.VersionString
            Build    = [System.Environment]::OSVersion.Version.Build
            Is64Bit  = [System.Environment]::Is64BitOperatingSystem
        }
        RAM_GB       = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        Disk_C_FreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        Git          = $(try { & git --version 2>$null } catch { "Non installe" })
        VSCode       = $(try { & code --version 2>$null | Select-Object -First 1 } catch { "Non installe" })
        WSL          = $(try { wsl --list --quiet 2>$null | Where-Object { $_ } } catch { "Non disponible" })
        ClaudeWin    = $(try { $v = & "$env:USERPROFILE\.local\bin\claude.exe" --version 2>$null; if ($v) { $v } else { "Non installe" } } catch { "Non installe" })
        ClaudeWSL    = $(try { $v = (wsl -d $Config.WSLDistro -- bash -c "~/.local/bin/claude --version 2>/dev/null" 2>$null | Out-String).Trim(); if ($v -match "\d+\.\d+") { $v } else { "Non installe" } } catch { "Non installe" })
        ClaudeDesktop = $(try { $v = (Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue | Select-Object -First 1).Version; if ($v) { $v } else { "Non installe" } } catch { "Non installe" })
        Winget       = $(try { (Get-Command winget -ErrorAction SilentlyContinue) -ne $null } catch { $false })
        Proxy        = @{
            HTTP_PROXY  = $env:HTTP_PROXY
            HTTPS_PROXY = $env:HTTPS_PROXY
            Configured  = [bool]$ProxyUrl
        }
    }

    # Sauvegarder l'inventaire
    $inventoryPath = "$env:LOCALAPPDATA\ClaudeCode\pre-flight-inventory.json"
    try {
        $invDir = Split-Path $inventoryPath -Parent
        if (-not (Test-Path $invDir)) {
            New-Item -ItemType Directory -Path $invDir -Force | Out-Null
        }
        $inventory | ConvertTo-Json -Depth 5 | Set-Content $inventoryPath -Encoding UTF8
        Write-Log "Inventaire sauvegarde: $inventoryPath" -Level "SUCCESS"
    }
    catch {
        Write-Log "Impossible de sauvegarder l'inventaire: $_" -Level "WARN"
    }

    # Afficher un resume
    Write-Log "  OS: $($inventory.OS.Version) (Build $($inventory.OS.Build))" -Level "INFO"
    Write-Log "  RAM: $($inventory.RAM_GB) GB | Disque C libre: $($inventory.Disk_C_FreeGB) GB" -Level "INFO"
    Write-Log "  Git: $($inventory.Git)" -Level "INFO"
    Write-Log "  VS Code: $($inventory.VSCode)" -Level "INFO"
    Write-Log "  Claude (Win): $($inventory.ClaudeWin)" -Level "INFO"
    Write-Log "  Claude (WSL): $($inventory.ClaudeWSL)" -Level "INFO"
}

# ============================================================================
# ETAPE 0 : VERIFICATIONS PRELIMINAIRES
# ============================================================================

function Step-Prerequisites {
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 0 : Verifications preliminaires" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # Configurer le proxy si specifie
    if ($ProxyUrl) {
        Write-Log "Configuration du proxy: $ProxyUrl" -Level "INFO"
        try {
            [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($ProxyUrl)
            [System.Net.WebRequest]::DefaultWebProxy.BypassProxyOnLocal = $true
            $env:HTTP_PROXY = $ProxyUrl
            $env:HTTPS_PROXY = $ProxyUrl
            $env:http_proxy = $ProxyUrl
            $env:https_proxy = $ProxyUrl
            Write-Log "Proxy configure pour la session: $ProxyUrl" -Level "SUCCESS"
        }
        catch {
            Write-Log "Erreur de configuration proxy: $_" -Level "ERROR"
            return $false
        }
    }

    # Verifier les droits admin
    if (-not (Test-AdminPrivileges)) {
        Write-Log "Ce script necessite des droits administrateur. Relancez en tant qu'admin." -Level "ERROR"
        Write-Log "Astuce: clic droit sur PowerShell > Executer en tant qu'administrateur" -Level "INFO"
        return $false
    }
    Write-Log "Droits administrateur confirmes" -Level "SUCCESS"

    # Verifier la version Windows
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Build -lt 18362) {
        Write-Log "Windows 10 version 1903+ requis (build 18362+). Build actuel: $($osVersion.Build)" -Level "ERROR"
        return $false
    }
    Write-Log "Version Windows compatible: Build $($osVersion.Build)" -Level "SUCCESS"

    # Verifier redemarrage en attente
    if (-not $SkipRebootCheck -and (Test-RebootPending)) {
        Write-Log "Un redemarrage est en attente. Redemarrez avant de relancer le script." -Level "WARN"
        Write-Log "Ou utilisez -SkipRebootCheck pour ignorer." -Level "INFO"
        return $false
    }

    # Verifier la connectivite reseau
    # URLs critiques (bloquent si inaccessibles)
    $criticalUrls = @("claude.ai")
    # URLs optionnelles (avertissement seulement)
    $optionalUrls = @("code.visualstudio.com", "downloads.claude.ai", "github.com")

    foreach ($url in $criticalUrls) {
        if (Test-Connection -ComputerName $url -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            Write-Log "Connectivite OK (critique): $url" -Level "SUCCESS"
        }
        else {
            Write-Log "Impossible de joindre $url - ce serveur est requis pour Claude" -Level "ERROR"
            return $false
        }
    }

    foreach ($url in $optionalUrls) {
        if (Test-Connection -ComputerName $url -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            Write-Log "Connectivite OK: $url" -Level "SUCCESS"
        }
        else {
            Write-Log "Impossible de joindre $url - certaines installations pourraient echouer" -Level "WARN"
        }
    }

    # Verifier winget (necessaire pour auto-install Git et VS Code)
    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetPath) {
        Write-Log "winget disponible pour les installations automatiques" -Level "SUCCESS"
    }
    else {
        Write-Log "winget non disponible. Git et VS Code devront etre installes manuellement si absents." -Level "WARN"
    }

    # Verifier / installer Git for Windows
    $gitPath = Get-Command git -ErrorAction SilentlyContinue
    if ($gitPath) {
        $gitVersion = & git --version 2>$null
        Write-Log "Git trouve: $gitVersion" -Level "SUCCESS"
    }
    else {
        Write-Log "Git for Windows non trouve (requis par Claude Code)" -Level "WARN"
        if ($wingetPath) {
            Write-Log "Installation de Git for Windows via winget..." -Level "INFO"
            Invoke-WithDryRun "Install Git for Windows via winget" {
                winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
                # Rafraichir PATH pour la session courante
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
            }
            # Verifier apres installation
            $gitCheck = Get-Command git -ErrorAction SilentlyContinue
            if ($gitCheck) {
                Write-Log "Git for Windows installe avec succes" -Level "SUCCESS"
            }
            else {
                Write-Log "Git installe mais non detecte dans PATH. Un redemarrage de la session peut etre requis." -Level "WARN"
            }
        }
        else {
            Write-Log "Installez Git manuellement: https://git-scm.com/download/win" -Level "WARN"
        }
    }

    # Verifier le plugin source si specifie
    if ($PluginSourcePath -and -not (Test-Path $PluginSourcePath)) {
        Write-Log "Chemin du plugin introuvable: $PluginSourcePath" -Level "WARN"
        Write-Log "Le plugin sera ignore. Vous pourrez l'installer manuellement plus tard." -Level "INFO"
    }

    # TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "TLS 1.2 active pour les telechargements" -Level "SUCCESS"

    return $true
}

# ============================================================================
# ETAPE 1 : VIRTUAL MACHINE PLATFORM + WSL2
# ============================================================================

function Step-WSL2Setup {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 1 : Configuration WSL2 et Virtual Machine Platform" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    $needsReboot = $false

    # Verifier Virtual Machine Platform (requis pour Cowork aussi)
    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction SilentlyContinue
    if ($vmpFeature.State -ne "Enabled") {
        Write-Log "Activation de Virtual Machine Platform..." -Level "INFO"
        if ($DryRun) {
            Write-Log "[DRY RUN] Virtual Machine Platform SERAIT active (redemarrage serait requis)" -Level "WARN"
        }
        else {
            Invoke-WithDryRun "Enable Virtual Machine Platform" {
                Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -All -NoRestart | Out-Null
            }
            $needsReboot = $true
            Write-Log "Virtual Machine Platform active (redemarrage requis)" -Level "SUCCESS"
        }
    }
    else {
        Write-Log "Virtual Machine Platform deja active" -Level "SUCCESS"
    }

    # Verifier WSL
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
    if ($wslFeature.State -ne "Enabled") {
        Write-Log "Activation de Windows Subsystem for Linux..." -Level "INFO"
        if ($DryRun) {
            Write-Log "[DRY RUN] WSL SERAIT active (redemarrage serait requis)" -Level "WARN"
        }
        else {
            Invoke-WithDryRun "Enable WSL Feature" {
                Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -All -NoRestart | Out-Null
            }
            $needsReboot = $true
            Write-Log "WSL active (redemarrage requis)" -Level "SUCCESS"
        }
    }
    else {
        Write-Log "WSL deja active" -Level "SUCCESS"
    }

    if ($needsReboot) {
        Write-Log "REDEMARRAGE REQUIS avant de continuer. Relancez le script apres le reboot." -Level "WARN"
        Write-Log "Le script reprendra automatiquement les etapes suivantes." -Level "INFO"
        return "REBOOT_NEEDED"
    }

    # Configurer WSL2 comme defaut
    Invoke-WithDryRun "Set WSL default version to 2" {
        wsl --set-default-version 2 2>$null | Out-Null
    }
    Write-Log "WSL2 configure comme version par defaut" -Level "SUCCESS"

    # Verifier si la distro est installee et enregistree
    $wslList = (wsl --list --quiet 2>$null | Out-String)

    if ($wslList -notmatch "Ubuntu") {
        Write-Log "Installation de $($Config.WSLDistro) (unattended)..." -Level "INFO"

        # Etape 1: Telecharger le package si necessaire
        Invoke-WithDryRun "Download WSL distro package" {
            wsl --install -d $Config.WSLDistro --no-launch --web-download 2>$null
        }

        # Etape 2: Trouver le launcher ubuntu et enregistrer avec root
        # Le launcher peut etre dans le PATH (user normal) ou dans WindowsApps (admin)
        Invoke-WithDryRun "Register WSL distro with root (unattended)" {
            $launcherPath = $null
            # Chercher dans le PATH d'abord
            $launcherPath = (Get-Command "ubuntu2204.exe" -ErrorAction SilentlyContinue).Source
            if (-not $launcherPath) {
                $launcherPath = (Get-Command "ubuntu2204" -ErrorAction SilentlyContinue).Source
            }
            # Chercher dans les AppxPackages
            if (-not $launcherPath) {
                $pkg = Get-AppxPackage -AllUsers -Name "*Ubuntu*22.04*" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($pkg) {
                    $candidate = Join-Path $pkg.InstallLocation "ubuntu2204.exe"
                    if (Test-Path $candidate) { $launcherPath = $candidate }
                }
            }
            if ($launcherPath) {
                Write-Log "Launcher trouve: $launcherPath" -Level "INFO"
                & $launcherPath install --root 2>$null
            }
            else {
                Write-Log "Launcher ubuntu2204.exe introuvable. Tentative via wsl --import..." -Level "WARN"
                # Fallback: la distro a peut-etre ete telechargee par --no-launch, essayer de la lancer
                wsl -d $Config.WSLDistro -- echo "Distro OK" 2>$null
            }
        }
        Write-Log "$($Config.WSLDistro) installe (mode root)" -Level "SUCCESS"

        # Etape 3: Creer l'utilisateur non-root
        $wslUser = $WSLUser
        Write-Log "Creation de l'utilisateur WSL: $wslUser" -Level "INFO"
        Invoke-WithDryRun "Create WSL user $wslUser" {
            wsl -d $Config.WSLDistro -- bash -c "id $wslUser 2>/dev/null || (useradd -m -s /bin/bash $wslUser && echo '${wslUser}:claude2026' | chpasswd && usermod -aG sudo $wslUser)"
            # Configurer comme utilisateur par defaut via wsl.conf
            wsl -d $Config.WSLDistro -- bash -c "grep -q 'default=' /etc/wsl.conf 2>/dev/null || (echo '[user]' > /etc/wsl.conf && echo 'default=$wslUser' >> /etc/wsl.conf)"
            # Redemarrer WSL pour appliquer wsl.conf
            wsl --shutdown
        }
        Write-Log "Utilisateur $wslUser cree et configure comme defaut" -Level "SUCCESS"

        # Etape 4: Configurer comme distro par defaut
        Invoke-WithDryRun "Set $($Config.WSLDistro) as default WSL distro" {
            wsl --set-default $Config.WSLDistro 2>$null
        }
        Write-Log "$($Config.WSLDistro) configure comme distro par defaut" -Level "SUCCESS"
    }
    else {
        Write-Log "Distribution Ubuntu deja installee dans WSL" -Level "SUCCESS"
        # S'assurer qu'elle est la distro par defaut
        Invoke-WithDryRun "Ensure $($Config.WSLDistro) is default" {
            wsl --set-default $Config.WSLDistro 2>$null
        }
    }

    return "OK"
}

# ============================================================================
# ETAPE 2 : CLAUDE CODE CLI DANS WSL2
# ============================================================================

function Step-ClaudeCodeWSL {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 2 : Installation de Claude Code CLI dans WSL2" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # Verifier si Claude Code est deja installe dans WSL
    $existingVersion = $null
    try {
        $raw = wsl -d $Config.WSLDistro -- bash -c "claude --version 2>/dev/null" 2>$null
        $rawStr = ($raw | Out-String).Trim()
        # Chercher un pattern de version valide (ex: "1.0.34", "claude 1.2.3")
        if ($rawStr -match "\d+\.\d+") { $existingVersion = $rawStr }
    }
    catch { }

    if ($existingVersion -and -not $ForceReinstall) {
        Write-Log "Claude Code deja installe dans WSL2: $existingVersion" -Level "SUCCESS"
        return $true
    }

    Write-Log "Installation de Claude Code (canal: $($Config.ClaudeCodeChannel))..." -Level "INFO"

    # Installer via le native installer dans WSL
    Invoke-WithDryRun "Install Claude Code CLI in WSL2" {
        $installCmd = "curl -fsSL https://claude.ai/install.sh | bash -s $($Config.ClaudeCodeChannel)"
        wsl -d $Config.WSLDistro -- bash -c $installCmd
    }

    # Verifier l'installation (skip en DryRun car WSL retourne des erreurs)
    if (-not $DryRun) {
        $version = $null
        try {
            $rawVer = wsl -d $Config.WSLDistro -- bash -c "~/.local/bin/claude --version 2>/dev/null" 2>$null
            $rawVerStr = ($rawVer | Out-String).Trim()
            if ($rawVerStr -match "\d+\.\d+") { $version = $rawVerStr }
        }
        catch { }
        if ($version) {
            Write-Log "Claude Code CLI installe avec succes: $version" -Level "SUCCESS"
        }
        else {
            Write-Log "L'installation de Claude Code CLI semble avoir echoue. Verifiez WSL." -Level "WARN"
        }
    }
    else {
        Write-Log "[DRY RUN] Verification post-install ignoree (WSL non disponible en simulation)" -Level "INFO"
    }

    return $true
}

# ============================================================================
# ETAPE 3 : CLAUDE CODE CLI SUR WINDOWS (PowerShell)
# ============================================================================

function Step-ClaudeCodeWindows {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 3 : Installation de Claude Code CLI sur Windows" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # Verifier si deja installe
    $existingVersion = $null
    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
    if (Test-Path $claudeExe) {
        try { $existingVersion = & $claudeExe --version 2>$null } catch { }
    }

    if ($existingVersion -and -not $ForceReinstall) {
        Write-Log "Claude Code deja installe sur Windows: $existingVersion" -Level "SUCCESS"
        return $true
    }

    Write-Log "Installation de Claude Code sur Windows..." -Level "INFO"

    Invoke-WithDryRun "Install Claude Code CLI on Windows" {
        # Utiliser l'installateur natif Windows
        $installScript = Invoke-RestMethod -Uri "https://claude.ai/install.ps1"
        Invoke-Expression $installScript
    }

    # Ajouter au PATH si necessaire
    $claudePath = "$env:USERPROFILE\.local\bin"
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$claudePath*") {
        Invoke-WithDryRun "Add Claude to User PATH" {
            [Environment]::SetEnvironmentVariable("Path", "$currentPath;$claudePath", "User")
        }
        Write-Log "Claude Code ajoute au PATH utilisateur" -Level "SUCCESS"
    }

    Write-Log "Claude Code CLI installe sur Windows" -Level "SUCCESS"
    return $true
}

# ============================================================================
# ETAPE 4 : CLAUDE DESKTOP / COWORK (MSIX)
# ============================================================================

function Step-ClaudeDesktop {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 4 : Installation de Claude Desktop (Cowork)" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # Verifier si deja installe
    $claudeApp = Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($claudeApp -and -not $ForceReinstall) {
        Write-Log "Claude Desktop deja installe: v$($claudeApp.Version)" -Level "SUCCESS"
        return $true
    }

    # Ref: https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows
    # Methode officielle Anthropic: MSIX package + Add-AppxPackage (ou Add-AppxProvisionedPackage pour machine-wide)
    Write-Log "Telechargement de Claude Desktop (MSIX officiel)..." -Level "INFO"

    $downloadUrl = "https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"
    $installerPath = "$env:TEMP\Claude.msix"

    Invoke-WithDryRun "Download Claude Desktop MSIX" {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
    }

    if (Test-Path $installerPath) {
        Write-Log "Installation de Claude Desktop (MSIX)..." -Level "INFO"

        # Machine-wide provisioning (admin) vs single-user
        $isAdmin = Test-AdminPrivileges
        if ($isAdmin) {
            Invoke-WithDryRun "Install Claude Desktop (machine-wide provisioning)" {
                Add-AppxProvisionedPackage -Online -PackagePath $installerPath -SkipLicense -Regions "all" -ErrorAction SilentlyContinue
            }
            Write-Log "Claude Desktop provisionne pour tous les utilisateurs (machine-wide)" -Level "SUCCESS"
        }
        else {
            Invoke-WithDryRun "Install Claude Desktop (single user)" {
                Add-AppxPackage -Path $installerPath -ErrorAction SilentlyContinue
            }
            Write-Log "Claude Desktop installe pour l'utilisateur courant" -Level "SUCCESS"
        }

        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

        # Rappel: Cowork necessite Virtual Machine Platform (verifie a l'etape 1)
        $vmpCheck = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction SilentlyContinue
        if ($vmpCheck.State -ne "Enabled") {
            Write-Log "ATTENTION: Virtual Machine Platform requis pour Cowork. Activez-le et redemarrez." -Level "WARN"
        }
        else {
            Write-Log "Cowork pret (Virtual Machine Platform active)" -Level "SUCCESS"
        }
    }
    else {
        Write-Log "Echec du telechargement MSIX. Installez manuellement depuis https://claude.ai/download" -Level "WARN"
    }

    return $true
}

# ============================================================================
# ETAPE 5 : EXTENSIONS VS CODE
# ============================================================================

function Step-VSCodeExtensions {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 5 : Installation des extensions VS Code" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # Trouver l'executable VS Code
    $codePaths = @(
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        (Get-Command code -ErrorAction SilentlyContinue).Source
    )

    $codePath = $codePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    # Auto-install VS Code si absent
    if (-not $codePath) {
        Write-Log "VS Code non trouve. Tentative d'installation automatique..." -Level "WARN"
        $wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetAvailable) {
            Invoke-WithDryRun "Install VS Code via winget" {
                winget install --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
                # Rafraichir PATH
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
            }
            # Re-chercher VS Code apres installation
            $codePaths = @(
                "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
                (Get-Command code -ErrorAction SilentlyContinue).Source
            )
            $codePath = $codePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        }

        if (-not $codePath) {
            Write-Log "VS Code non disponible. Extensions a installer manuellement." -Level "WARN"
            Write-Log "Telechargez VS Code: https://code.visualstudio.com/download" -Level "INFO"
            Write-Log "Extensions requises: $($Config.VSCodeExtensions -join ', ')" -Level "INFO"
            return $true
        }
        Write-Log "VS Code installe avec succes" -Level "SUCCESS"
    }

    Write-Log "VS Code trouve: $codePath" -Level "SUCCESS"

    # Pre-check: lister les extensions deja installees
    $installedExtensions = @()
    if (-not $ForceReinstall) {
        $installedExtensions = & $codePath --list-extensions 2>$null
    }

    foreach ($ext in $Config.VSCodeExtensions) {
        if ($installedExtensions -contains $ext) {
            Write-Log "Extension deja installee: $ext" -Level "SUCCESS"
            continue
        }
        Write-Log "Installation de l'extension: $ext" -Level "INFO"
        Invoke-WithDryRun "Install VS Code extension: $ext" {
            & $codePath --install-extension $ext --force 2>&1 | Out-Null
        }
        Write-Log "Extension installee: $ext" -Level "SUCCESS"
    }

    # Configurer les settings VS Code pour Claude
    $vsCodeSettingsDir = "$env:APPDATA\Code\User"
    $vsCodeSettingsFile = "$vsCodeSettingsDir\settings.json"

    if (Test-Path $vsCodeSettingsFile) {
        # VS Code settings.json peut contenir des commentaires // que ConvertFrom-Json ne supporte pas
        $rawJson = Get-Content $vsCodeSettingsFile -Raw
        $cleanJson = ($rawJson -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        try {
            $currentSettings = $cleanJson | ConvertFrom-Json
        }
        catch {
            Write-Log "Impossible de parser le settings.json VS Code (JSON invalide). Skip merge." -Level "WARN"
            $currentSettings = $null
        }
    }
    else {
        $currentSettings = [PSCustomObject]@{}
    }

    # Ajouter les settings Claude Code si pas deja presents
    $claudeSettings = @{
        "claudeCode.autosave"          = $true
        "claudeCode.respectGitIgnore"  = $true
    }

    $modified = $false
    if ($currentSettings) {
        foreach ($key in $claudeSettings.Keys) {
            if (-not ($currentSettings.PSObject.Properties.Name -contains $key)) {
                $currentSettings | Add-Member -NotePropertyName $key -NotePropertyValue $claudeSettings[$key] -Force
                $modified = $true
            }
        }
    }

    if ($modified) {
        Invoke-WithDryRun "Update VS Code settings for Claude" {
            New-Item -ItemType Directory -Path $vsCodeSettingsDir -Force | Out-Null
            $currentSettings | ConvertTo-Json -Depth 10 | Set-Content $vsCodeSettingsFile -Encoding UTF8
        }
        Write-Log "Settings VS Code mis a jour pour Claude Code" -Level "SUCCESS"
    }

    # ---- VS Code Tasks: Ctrl+Shift+P > "Run Task" > Claude Code ----
    $tasksDir = "$vsCodeSettingsDir"
    $tasksFile = "$tasksDir\tasks.json"

    if (-not (Test-Path $tasksFile)) {
        Invoke-WithDryRun "Create VS Code tasks for Claude Code" {
            $tasksJson = @{
                version = "2.0.0"
                tasks = @(
                    @{
                        label       = "Claude Code (WSL)"
                        type        = "shell"
                        command     = "wsl -d $($Config.WSLDistro) -- claude"
                        group       = "none"
                        presentation = @{
                            reveal = "always"
                            panel  = "dedicated"
                            focus  = $true
                        }
                        problemMatcher = @()
                    }
                    @{
                        label       = "Claude Code Chat (WSL)"
                        type        = "shell"
                        command     = "wsl -d $($Config.WSLDistro) -- claude chat"
                        group       = "none"
                        presentation = @{
                            reveal = "always"
                            panel  = "dedicated"
                            focus  = $true
                        }
                        problemMatcher = @()
                    }
                    @{
                        label       = "Ouvrir WSL Remote"
                        type        = "shell"
                        command     = "code --remote wsl+$($Config.WSLDistro) /home/$WSLUser"
                        group       = "none"
                        presentation = @{ reveal = "silent" }
                        problemMatcher = @()
                    }
                )
            }
            New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
            $tasksJson | ConvertTo-Json -Depth 10 | Set-Content $tasksFile -Encoding UTF8
        }
        Write-Log "Tasks VS Code creees (Claude Code WSL, Chat, Remote)" -Level "SUCCESS"
    }
    else {
        Write-Log "Tasks VS Code deja presentes - conservees" -Level "INFO"
    }

    # ---- VS Code Keybindings: Ctrl+Shift+Alt+C pour lancer Claude dans WSL ----
    $keybindingsFile = "$vsCodeSettingsDir\keybindings.json"

    if (-not (Test-Path $keybindingsFile)) {
        Invoke-WithDryRun "Create VS Code keybindings for Claude" {
            $keybindings = @(
                @{
                    key     = "ctrl+shift+alt+c"
                    command = "workbench.action.tasks.runTask"
                    args    = "Claude Code (WSL)"
                }
                @{
                    key     = "ctrl+shift+alt+w"
                    command = "workbench.action.tasks.runTask"
                    args    = "Ouvrir WSL Remote"
                }
            )
            $keybindings | ConvertTo-Json -Depth 5 | Set-Content $keybindingsFile -Encoding UTF8
        }
        Write-Log "Keybindings VS Code: Ctrl+Shift+Alt+C (Claude), Ctrl+Shift+Alt+W (WSL Remote)" -Level "SUCCESS"
    }
    else {
        Write-Log "Keybindings VS Code deja presentes - conservees" -Level "INFO"
    }

    # ---- Raccourci Desktop: "Claude Code WSL" ----
    $desktopShortcut = "$env:USERPROFILE\Desktop\Claude Code WSL.lnk"
    if (-not (Test-Path $desktopShortcut)) {
        Invoke-WithDryRun "Create desktop shortcut for Claude Code WSL" {
            $codeExe = (Get-Command code -ErrorAction SilentlyContinue).Source
            if (-not $codeExe) {
                # Chercher le .exe directement
                $codeExe = @(
                    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
                    "$env:ProgramFiles\Microsoft VS Code\Code.exe"
                ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            }
            if ($codeExe) {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($desktopShortcut)
                $shortcut.TargetPath = $codeExe
                $shortcut.Arguments = "--remote wsl+$($Config.WSLDistro) /home/$WSLUser"
                $shortcut.Description = "VS Code connecte a WSL Ubuntu avec Claude Code"
                $shortcut.WorkingDirectory = "$env:USERPROFILE"
                $shortcut.Save()
            }
        }
        Write-Log "Raccourci Desktop cree: Claude Code WSL" -Level "SUCCESS"
    }
    else {
        Write-Log "Raccourci Desktop deja present" -Level "INFO"
    }

    return $true
}

# ============================================================================
# ETAPE 6 : CONFIGURATION CENTRALISEE (managed-settings.json)
# ============================================================================

function Step-ManagedSettings {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 6 : Deploiement de la configuration centralisee" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # ---- Migrer legacy path si present (ProgramData -> Program Files) ----
    if (Test-Path $Config.ManagedSettingsLegacy) {
        Write-Log "Migration du managed-settings.json depuis ProgramData (deprecie v2.1.75)..." -Level "WARN"
        Invoke-WithDryRun "Migrate managed-settings from legacy path" {
            $newDir = Split-Path $Config.ManagedSettingsWin -Parent
            New-Item -ItemType Directory -Path $newDir -Force | Out-Null
            Move-Item $Config.ManagedSettingsLegacy $Config.ManagedSettingsWin -Force
            # Nettoyer l'ancien dossier si vide
            $legacyDir = Split-Path $Config.ManagedSettingsLegacy -Parent
            if ((Get-ChildItem $legacyDir -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item $legacyDir -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Log "Migre vers: $($Config.ManagedSettingsWin)" -Level "SUCCESS"
    }

    # ---- Managed Settings (admin, ne peut pas etre override par l'utilisateur) ----
    # Schema officiel: https://json.schemastore.org/claude-code-settings.json
    # Ref: https://support.claude.com/en/articles/12622667-enterprise-configuration
    $managedSettings = @{
        '$schema'                      = "https://json.schemastore.org/claude-code-settings.json"

        # Securite
        disableBypassPermissionsMode   = $true
        allowManagedPermissionRulesOnly = $false    # false pour le POC, true en prod
        allowManagedHooksOnly          = $false    # false pour le POC, true en prod

        # Canal de mise a jour
        autoUpdatesChannel             = $Config.AutoUpdatesChannel

        # Langue
        language                       = "french"

        # Permissions centralisees (format Anthropic officiel)
        permissions = @{
            deny = @(
                "Bash(rm -rf /)"
                "Bash(sudo rm -rf *)"
                "Bash(format *)"
                "Bash(del /s /q C:*)"
            )
        }
    }

    # Utiliser un fichier personnalise si fourni
    if ($ManagedSettingsPath -and (Test-Path $ManagedSettingsPath)) {
        Write-Log "Utilisation du managed-settings.json personnalise: $ManagedSettingsPath" -Level "INFO"
        $managedSettings = Get-Content $ManagedSettingsPath -Raw | ConvertFrom-Json
    }

    # Deployer sur Windows (C:\Program Files\ClaudeCode\)
    Invoke-WithDryRun "Deploy managed-settings.json (Windows: Program Files)" {
        $managedDir = Split-Path $Config.ManagedSettingsWin -Parent
        New-Item -ItemType Directory -Path $managedDir -Force | Out-Null
        $managedSettings | ConvertTo-Json -Depth 10 | Set-Content $Config.ManagedSettingsWin -Encoding UTF8
    }
    Write-Log "managed-settings.json deploye: $($Config.ManagedSettingsWin)" -Level "SUCCESS"

    # Deployer dans WSL2 aussi (/etc/claude-code/)
    Invoke-WithDryRun "Deploy managed-settings.json (WSL2: /etc/claude-code/)" {
        $json = ($managedSettings | ConvertTo-Json -Depth 10 -Compress)
        $cmd = "sudo mkdir -p /etc/claude-code && echo '$json' | sudo tee /etc/claude-code/managed-settings.json > /dev/null"
        wsl -d $Config.WSLDistro -- bash -c $cmd
    }
    Write-Log "managed-settings.json deploye dans WSL2: /etc/claude-code/" -Level "SUCCESS"

    # ---- Claude Desktop Registry Policies ----
    # Ref: https://support.claude.com/en/articles/12622667-enterprise-configuration
    # HKLM:\SOFTWARE\Policies\Claude pour les politiques machine
    Invoke-WithDryRun "Deploy Claude Desktop registry policies" {
        $regPath = "HKLM:\SOFTWARE\Policies\Claude"
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        # Cowork actif
        Set-ItemProperty -Path $regPath -Name "secureVmFeaturesEnabled" -Value 1 -Type DWord
        # Extensions et MCP actifs
        Set-ItemProperty -Path $regPath -Name "isDesktopExtensionEnabled" -Value 1 -Type DWord
        Set-ItemProperty -Path $regPath -Name "isLocalDevMcpEnabled" -Value 1 -Type DWord
        Set-ItemProperty -Path $regPath -Name "isClaudeCodeForDesktopEnabled" -Value 1 -Type DWord
        # Auto-updates: forcer restart dans 72h max
        Set-ItemProperty -Path $regPath -Name "autoUpdaterEnforcementHours" -Value 72 -Type DWord
    }
    Write-Log "Politiques registre Claude Desktop configurees (HKLM)" -Level "SUCCESS"

    # ---- User Settings (preferences par defaut, merge seulement) ----
    $defaultUserSettings = @{
        autoUpdatesChannel = $Config.AutoUpdatesChannel
        language           = "french"
    }

    $userSettingsFile = Join-Path $Config.UserSettingsDir "settings.json"

    if (Test-Path $userSettingsFile) {
        # Backup avant toute modification
        $backupPath = "$userSettingsFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Invoke-WithDryRun "Backup existing user settings" {
            Copy-Item $userSettingsFile $backupPath
        }
        Write-Log "Backup des settings existants: $backupPath" -Level "INFO"

        # Merge: injecter seulement les cles manquantes, ne jamais supprimer
        try {
            $existing = Get-Content $userSettingsFile -Raw | ConvertFrom-Json
            $merged = $false
            foreach ($key in $defaultUserSettings.Keys) {
                if (-not ($existing.PSObject.Properties.Name -contains $key)) {
                    $existing | Add-Member -NotePropertyName $key -NotePropertyValue $defaultUserSettings[$key] -Force
                    $merged = $true
                }
            }
            if ($merged) {
                Invoke-WithDryRun "Merge missing keys into user settings.json" {
                    $existing | ConvertTo-Json -Depth 10 | Set-Content $userSettingsFile -Encoding UTF8
                }
                Write-Log "Settings utilisateur mis a jour (cles manquantes ajoutees)" -Level "SUCCESS"
            }
            else {
                Write-Log "Settings utilisateur complets - aucune modification necessaire" -Level "SUCCESS"
            }
        }
        catch {
            Write-Log "Impossible de parser le settings.json existant: $_" -Level "WARN"
        }
    }
    else {
        # Nouveau fichier: deployer les defaults complets
        $newUserSettings = @{
            autoUpdatesChannel = $Config.AutoUpdatesChannel
            language           = "french"
            permissions        = @{
                allow = @("Read(*)", "Glob(*)", "Grep(*)")
                defaultMode = "allowEdits"
            }
        }
        Invoke-WithDryRun "Deploy new user settings.json" {
            New-Item -ItemType Directory -Path $Config.UserSettingsDir -Force | Out-Null
            $newUserSettings | ConvertTo-Json -Depth 10 | Set-Content $userSettingsFile -Encoding UTF8
        }
        Write-Log "Nouveau settings.json deploye: $userSettingsFile" -Level "SUCCESS"
    }

    return $true
}

# ============================================================================
# ETAPE 7 : PLUGIN GENIE GMS
# ============================================================================

function Step-DeployPlugin {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 7 : Deploiement du plugin Genie GMS" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    if (-not $PluginSourcePath) {
        Write-Log "Aucun chemin de plugin specifie (-PluginSourcePath). Etape ignoree." -Level "WARN"
        Write-Log "Le plugin pourra etre installe plus tard via: claude /plugin install [source]" -Level "INFO"
        return $true
    }

    if (-not (Test-Path $PluginSourcePath)) {
        Write-Log "Chemin du plugin introuvable: $PluginSourcePath" -Level "WARN"
        return $true
    }

    # Copier le plugin dans le repertoire des plugins utilisateur
    $pluginName = Split-Path $PluginSourcePath -Leaf
    $pluginDest = Join-Path $Config.PluginDeployDir $pluginName

    Write-Log "Copie du plugin: $pluginName -> $pluginDest" -Level "INFO"

    Invoke-WithDryRun "Copy plugin to user directory" {
        New-Item -ItemType Directory -Path $Config.PluginDeployDir -Force | Out-Null

        if (Test-Path $pluginDest) {
            Remove-Item $pluginDest -Recurse -Force
        }

        Copy-Item -Path $PluginSourcePath -Destination $pluginDest -Recurse -Force
    }

    Write-Log "Plugin $pluginName deploye" -Level "SUCCESS"

    # Copier aussi dans le WSL si accessible
    Invoke-WithDryRun "Deploy plugin to WSL2" {
        $wslPluginDir = "~/.claude/plugins/$pluginName"
        $wslSource = ($pluginDest -replace "\\", "/" -replace "^(\w):", '/mnt/$1'.ToLower())
        $cmd = "mkdir -p ~/.claude/plugins; cp -r '$wslSource' '$wslPluginDir' 2>/dev/null; echo 'Plugin WSL copy done'"
        wsl -d $Config.WSLDistro -- bash -c $cmd
    }

    return $true
}

# ============================================================================
# ETAPE 8 : AUTOCOMPLETION SHELL
# ============================================================================

function Step-ShellCompletion {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 8 : Configuration de l'autocompletion shell" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # ---- PowerShell (Windows) ----
    Write-Log "Configuration PowerShell..." -Level "INFO"

    $psProfileDir = Split-Path $PROFILE -Parent
    if (-not (Test-Path $psProfileDir)) {
        New-Item -ItemType Directory -Path $psProfileDir -Force | Out-Null
    }

    $completionBlock = @'

# === Claude Code Autocompletion ===
if (Get-Command claude -ErrorAction SilentlyContinue) {
    # Alias pratiques
    Set-Alias cc claude

    # Autocompletion pour claude
    Register-ArgumentCompleter -CommandName claude -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        $subcommands = @('chat', 'config', 'update', 'mcp', 'doctor', '--help', '--version', '--resume', '--continue')
        $subcommands | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    }
}
# === Fin Claude Code ===
'@

    # Verifier si deja ajoute
    if (Test-Path $PROFILE) {
        $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
        if ($profileContent -match "Claude Code Autocompletion") {
            Write-Log "Autocompletion PowerShell deja configuree" -Level "SUCCESS"
        }
        else {
            Invoke-WithDryRun "Add Claude completion to PowerShell profile" {
                Add-Content -Path $PROFILE -Value $completionBlock -Encoding UTF8
            }
            Write-Log "Autocompletion PowerShell ajoutee a $PROFILE" -Level "SUCCESS"
        }
    }
    else {
        Invoke-WithDryRun "Create PowerShell profile with Claude completion" {
            Set-Content -Path $PROFILE -Value $completionBlock -Encoding UTF8
        }
        Write-Log "Profil PowerShell cree avec autocompletion Claude" -Level "SUCCESS"
    }

    # ---- Bash dans WSL2 ----
    Write-Log "Configuration Bash/Zsh dans WSL2..." -Level "INFO"

    $bashCompletion = @'

# === Claude Code Shell Setup ===
# PATH
export PATH="$HOME/.local/bin:$PATH"

# Alias
alias cc='claude'
alias ccc='claude chat'
alias ccr='claude --resume'

# Autocompletion Bash pour Claude Code
if command -v claude >/dev/null 2>&1; then
    eval "$(claude completion bash 2>/dev/null)" || true
fi

# Prompt ameliore avec indicateur Claude
if [ -n "$CLAUDE_CODE_SESSION" ]; then
    PS1="[claude] $PS1"
fi
# === Fin Claude Code ===
'@

    Invoke-WithDryRun "Configure Bash completion in WSL2" {
        # Ecrire le bloc de completion dans un fichier temporaire, puis l'ajouter au .bashrc
        $tempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempFile -Value $bashCompletion -Encoding UTF8 -NoNewline
        $wslTempPath = ($tempFile -replace '\\', '/' -replace '^(\w):', '/mnt/$1'.ToLower())
        $cmd = 'grep -q "Claude Code Shell Setup" ~/.bashrc 2>/dev/null; if [ $? -ne 0 ]; then cat "' + $wslTempPath + '" >> ~/.bashrc; echo "Bash completion added"; else echo "Bash completion already configured"; fi'
        wsl -d $Config.WSLDistro -- bash -c $cmd
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Autocompletion Bash configuree dans WSL2" -Level "SUCCESS"

    # Zsh aussi si installe
    Invoke-WithDryRun "Configure Zsh completion in WSL2 (if available)" {
        $zshCompletion = $bashCompletion -replace 'completion bash', 'completion zsh'
        $tempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempFile -Value $zshCompletion -Encoding UTF8 -NoNewline
        $wslTempPath = ($tempFile -replace '\\', '/' -replace '^(\w):', '/mnt/$1'.ToLower())
        $cmd = 'if [ -f ~/.zshrc ]; then grep -q "Claude Code Shell Setup" ~/.zshrc 2>/dev/null; if [ $? -ne 0 ]; then cat "' + $wslTempPath + '" >> ~/.zshrc; echo "Zsh completion added"; fi; fi'
        wsl -d $Config.WSLDistro -- bash -c $cmd
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }

    return $true
}

# ============================================================================
# ETAPE 9 : MISE A JOUR AUTOMATIQUE (tache planifiee)
# ============================================================================

function Step-AutoUpdate {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 9 : Configuration de la mise a jour automatique" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    # Creer le script de mise a jour
    $updateScriptPath = "$env:ProgramData\ClaudeCode\Update-ClaudeCode.ps1"

    $updateScript = @'
<#
.SYNOPSIS
    Script de mise a jour automatique de Claude Code
    Execute par la tache planifiee ClaudeCode-AutoUpdate
#>

$logFile = "$env:ProgramData\ClaudeCode\update.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Log($msg) {
    "[$timestamp] $msg" | Add-Content $logFile -Encoding UTF8
}

try {
    Log "=== Debut de la mise a jour ==="

    # Mettre a jour Claude Code sur Windows
    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
    if (Test-Path $claudeExe) {
        Log "Mise a jour Claude Code Windows..."
        & $claudeExe update 2>&1 | ForEach-Object { Log $_ }
    }

    # Mettre a jour Claude Code dans WSL2
    Log "Mise a jour Claude Code WSL2..."
    wsl -- bash -c "~/.local/bin/claude update 2>&1" | ForEach-Object { Log $_ }

    # Mettre a jour les extensions VS Code
    $codePath = Get-Command code -ErrorAction SilentlyContinue
    if ($codePath) {
        Log "Mise a jour extension VS Code Claude Code..."
        & code --install-extension anthropic.claude-code --force 2>&1 | Out-Null
    }

    Log "=== Mise a jour terminee ==="
}
catch {
    Log "ERREUR: $_"
}
'@

    Invoke-WithDryRun "Create update script" {
        $updateDir = Split-Path $updateScriptPath -Parent
        New-Item -ItemType Directory -Path $updateDir -Force | Out-Null
        Set-Content -Path $updateScriptPath -Value $updateScript -Encoding UTF8
    }
    Write-Log "Script de mise a jour cree: $updateScriptPath" -Level "SUCCESS"

    # Creer la tache planifiee
    $taskExists = Get-ScheduledTask -TaskName $Config.UpdateTaskName -ErrorAction SilentlyContinue

    if ($taskExists -and -not $ForceReinstall) {
        Write-Log "Tache planifiee '$($Config.UpdateTaskName)' existe deja" -Level "SUCCESS"
        return $true
    }

    Invoke-WithDryRun "Create scheduled update task" {
        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updateScriptPath`""

        if ($Config.UpdateSchedule -eq "Weekly") {
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Tuesday -At $Config.UpdateTime
        }
        else {
            $trigger = New-ScheduledTaskTrigger -Daily -At $Config.UpdateTime
        }

        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

        Register-ScheduledTask `
            -TaskName $Config.UpdateTaskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Mise a jour automatique de Claude Code, extensions VS Code et plugins" `
            -Force | Out-Null
    }

    Write-Log "Tache planifiee creee: $($Config.UpdateTaskName) ($($Config.UpdateSchedule) a $($Config.UpdateTime))" -Level "SUCCESS"

    return $true
}

# ============================================================================
# ETAPE 10 : VALIDATION FINALE
# ============================================================================

function Step-Validation {
    Write-Log "" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"
    Write-Log "ETAPE 10 : Validation de l'installation" -Level "STEP"
    Write-Log "=" * 70 -Level "STEP"

    $results = @()

    # 1. Claude Code Windows
    $ccWin = $null
    $claudeExePath = "$env:USERPROFILE\.local\bin\claude.exe"
    if (Test-Path $claudeExePath) {
        try { $ccWin = & $claudeExePath --version 2>$null } catch { }
    }
    $results += [PSCustomObject]@{
        Composante = "Claude Code (Windows)"
        Statut     = if ($ccWin) { "OK" } else { "NON INSTALLE" }
        Version    = if ($ccWin) { $ccWin } else { "-" }
    }

    # 2. Claude Code WSL2
    $ccWSL = $null
    try {
        $rawWSL = wsl -d $Config.WSLDistro -- bash -c "~/.local/bin/claude --version 2>/dev/null" 2>$null
        $rawWSLStr = ($rawWSL | Out-String).Trim()
        if ($rawWSLStr -match "\d+\.\d+") { $ccWSL = $rawWSLStr }
    }
    catch { }
    $results += [PSCustomObject]@{
        Composante = "Claude Code (WSL2)"
        Statut     = if ($ccWSL) { "OK" } else { "NON INSTALLE" }
        Version    = if ($ccWSL) { $ccWSL } else { "-" }
    }

    # 3. Claude Desktop
    $desktop = Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $results += [PSCustomObject]@{
        Composante = "Claude Desktop (Cowork)"
        Statut     = if ($desktop) { "OK" } else { "NON INSTALLE" }
        Version    = if ($desktop) { "v$($desktop.Version)" } else { "-" }
    }

    # 4. VS Code Extension
    $codePath = Get-Command code -ErrorAction SilentlyContinue
    $extInstalled = $false
    if ($codePath) {
        $extensions = & code --list-extensions 2>$null
        $extInstalled = $extensions -contains "anthropic.claude-code"
    }
    $results += [PSCustomObject]@{
        Composante = "Extension VS Code"
        Statut     = if ($extInstalled) { "OK" } else { "NON INSTALLE" }
        Version    = if ($extInstalled) { "installee" } else { "-" }
    }

    # 5. Managed Settings
    $managedOK = Test-Path $Config.ManagedSettingsWin
    $results += [PSCustomObject]@{
        Composante = "managed-settings.json"
        Statut     = if ($managedOK) { "OK" } else { "MANQUANT" }
        Version    = if ($managedOK) { $Config.ManagedSettingsWin } else { "-" }
    }

    # 6. Plugin
    if ($PluginSourcePath) {
        $expectedPluginName = Split-Path $PluginSourcePath -Leaf
        $pluginOK = Test-Path (Join-Path $Config.PluginDeployDir $expectedPluginName)
    }
    else {
        $pluginOK = (Get-ChildItem $Config.PluginDeployDir -Directory -ErrorAction SilentlyContinue).Count -gt 0
    }
    $pluginLabel = if ($PluginSourcePath) { Split-Path $PluginSourcePath -Leaf } else { "Plugin" }
    $results += [PSCustomObject]@{
        Composante = "Plugin ($pluginLabel)"
        Statut     = if ($pluginOK) { "OK" } else { "NON DEPLOYE" }
        Version    = if ($pluginOK) { "deploye" } else { "-" }
    }

    # 7. Tache planifiee
    $taskOK = Get-ScheduledTask -TaskName $Config.UpdateTaskName -ErrorAction SilentlyContinue
    $results += [PSCustomObject]@{
        Composante = "Auto-Update Task"
        Statut     = if ($taskOK) { "OK" } else { "NON CONFIGURE" }
        Version    = if ($taskOK) { $Config.UpdateSchedule } else { "-" }
    }

    # Afficher le rapport
    Write-Log "" -Level "STEP"
    Write-Log "RAPPORT DE VALIDATION" -Level "STEP"
    Write-Log "-" * 70 -Level "STEP"

    # En mode AdminOnly, ne verifier que les composantes admin
    $adminComponents = @("managed-settings.json", "Auto-Update Task")
    $allOK = $true
    foreach ($r in $results) {
        $isAdminComponent = $adminComponents -contains $r.Composante
        if ($AdminOnly -and -not $isAdminComponent) {
            # Skip la verification des composantes user-space en mode admin
            Write-Log "$($r.Composante): SKIP (mode admin)" -Level "INFO"
            continue
        }
        $level = if ($r.Statut -eq "OK") { "SUCCESS" } else { "WARN" }
        Write-Log "$($r.Composante): $($r.Statut) ($($r.Version))" -Level $level
        if ($r.Statut -ne "OK") { $allOK = $false }
    }

    Write-Log "-" * 70 -Level "STEP"
    if ($allOK) {
        Write-Log "DEPLOIEMENT COMPLET - Toutes les composantes verifiees sont OK!" -Level "SUCCESS"
    }
    else {
        Write-Log "DEPLOIEMENT PARTIEL - Certaines composantes necessitent une attention." -Level "WARN"
    }

    # Exporter le rapport en JSON
    $reportPath = "$env:LOCALAPPDATA\ClaudeCode\validation-report.json"
    $report = @{
        Timestamp  = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        Computer   = $env:COMPUTERNAME
        User       = $env:USERNAME
        Results    = $results
        AllPassed  = $allOK
    }
    Invoke-WithDryRun "Export validation report to $reportPath" {
        New-Item -ItemType Directory -Path (Split-Path $reportPath -Parent) -Force | Out-Null
        $report | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8
    }
    Write-Log "Rapport JSON exporte: $reportPath" -Level "INFO"

    return $allOK
}

# ============================================================================
# EXECUTION PRINCIPALE
# ============================================================================

$banner = @"

  ====================================================================
     DEPLOIEMENT CLAUDE CODE & COWORK - G Mining Services (CAGM)
  ====================================================================
     Script  : Deploy-ClaudeCode.ps1 v3.0.0
     Date    : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
     Poste   : $env:COMPUTERNAME
     User    : $env:USERNAME
     Mode    : $(if ($DryRun) { "SIMULATION (Dry Run)" } else { "PRODUCTION" })
  ====================================================================

"@

Write-Host $banner -ForegroundColor Cyan

# Initialiser le log
Write-Log "Debut du deploiement - $env:COMPUTERNAME / $env:USERNAME"
if ($DryRun) { Write-Log "MODE DRY RUN ACTIVE - Aucune modification ne sera apportee" -Level "WARN" }
if ($ForceReinstall) { Write-Log "MODE FORCE REINSTALLATION active" -Level "WARN" }
if ($ProxyUrl) { Write-Log "Proxy configure: $ProxyUrl" -Level "INFO" }

# Inventaire pre-deploiement
Write-PreFlightInventory

# Verifier si on reprend apres un reboot
$resumeStep = Get-ResumeStep
if ($resumeStep -gt 0) {
    Write-Log "REPRISE apres reboot - Les $resumeStep premieres etapes seront ignorees" -Level "WARN"
}

# Executer les etapes
# AdminRequired: $true = necessite droits admin (managed-settings, features, scheduled task)
#                $false = fonctionne en user normal (CLI, extensions, bashrc, plugins)
#                $null = toujours executer (prerequis, validation)
$steps = @(
    @{ Name = "Prerequis";               Func = { Step-Prerequisites };     AdminRequired = $null }
    @{ Name = "WSL2";                     Func = { Step-WSL2Setup };         AdminRequired = $true }
    @{ Name = "Claude Code (WSL2)";       Func = { Step-ClaudeCodeWSL };     AdminRequired = $false }
    @{ Name = "Claude Code (Windows)";    Func = { Step-ClaudeCodeWindows }; AdminRequired = $false }
    @{ Name = "Claude Desktop (Cowork)";  Func = { Step-ClaudeDesktop };     AdminRequired = $false }
    @{ Name = "Extensions VS Code";       Func = { Step-VSCodeExtensions };  AdminRequired = $false }
    @{ Name = "Configuration centralisee"; Func = { Step-ManagedSettings };  AdminRequired = $true }
    @{ Name = "Plugin";                   Func = { Step-DeployPlugin };      AdminRequired = $false }
    @{ Name = "Autocompletion shell";     Func = { Step-ShellCompletion };   AdminRequired = $false }
    @{ Name = "Mise a jour automatique";  Func = { Step-AutoUpdate };        AdminRequired = $true }
    @{ Name = "Validation";               Func = { Step-Validation };        AdminRequired = $null }
)

if ($AdminOnly) {
    Write-Log "MODE ADMIN ONLY - Seules les etapes admin seront executees" -Level "WARN"
}

$startTime = Get-Date

for ($stepIndex = 0; $stepIndex -lt $steps.Count; $stepIndex++) {
    $step = $steps[$stepIndex]

    # Sauter les etapes deja completees (resume apres reboot)
    if ($stepIndex -lt $resumeStep) {
        Write-Log "SKIP etape $stepIndex '$($step.Name)' (deja completee avant reboot)" -Level "INFO"
        continue
    }

    # Mode hybride: filtrer selon AdminOnly
    if ($AdminOnly -and $step.AdminRequired -eq $false) {
        Write-Log "SKIP '$($step.Name)' (mode -AdminOnly, etape user-space)" -Level "INFO"
        continue
    }
    if (-not $AdminOnly -and $step.AdminRequired -eq $true) {
        Write-Log "SKIP '$($step.Name)' (pas admin, etape admin-only)" -Level "INFO"
        continue
    }

    $result = & $step.Func

    # Comparaisons strictes pour eviter la coercion PS ($true -eq "REBOOT_NEEDED" = $true!)
    if ($result -is [bool] -and $result -eq $false) {
        if ($DryRun) {
            Write-Log "[DRY RUN] L'etape '$($step.Name)' aurait echoue. Simulation continue..." -Level "WARN"
            continue
        }
        Write-Log "ARRET: L'etape '$($step.Name)' a echoue." -Level "ERROR"
        Write-Log "Corrigez le probleme et relancez le script." -Level "INFO"
        exit 1
    }

    if ($result -is [string] -and $result -eq "REBOOT_NEEDED") {
        if ($DryRun) {
            Write-Log "[DRY RUN] Un redemarrage serait necessaire ici. Simulation continue..." -Level "WARN"
            continue
        }
        Write-Log "" -Level "STEP"
        Write-Log "Configuration du resume automatique apres reboot..." -Level "INFO"
        Save-ResumeState -StepIndex ($stepIndex + 1)
        Write-Log "" -Level "STEP"
        Write-Log "REDEMARRAGE REQUIS - Le script reprendra automatiquement apres le reboot." -Level "WARN"
        Write-Log "Si le resume auto ne fonctionne pas, relancez manuellement:" -Level "INFO"
        Write-Log "  cd `"$(Split-Path $PSCommandPath -Parent)`"" -Level "INFO"
        Write-Log "  .\Deploy-ClaudeCode.ps1" -Level "INFO"
        exit 2
    }
}

# Deploiement complet - nettoyer l'etat de resume
Clear-ResumeState

$duration = (Get-Date) - $startTime
Write-Log "" -Level "STEP"
Write-Log "=" * 70 -Level "STEP"
Write-Log "DEPLOIEMENT TERMINE en $($duration.Minutes)m $($duration.Seconds)s" -Level "SUCCESS"
Write-Log "=" * 70 -Level "STEP"
Write-Log "Log complet: $($Config.LogFile)" -Level "INFO"
Write-Log "" -Level "STEP"
Write-Log "PROCHAINES ETAPES :" -Level "STEP"
Write-Log "  1. Ouvrez VS Code et lancez Claude Code (Ctrl+Shift+P > Claude Code)" -Level "INFO"
Write-Log "  2. Authentifiez-vous via OAuth (SSO Microsoft gmining.com)" -Level "INFO"
Write-Log "  3. Dans le terminal WSL, tapez 'claude' pour la premiere connexion" -Level "INFO"
Write-Log "  4. Ouvrez Claude Desktop pour acceder a Cowork" -Level "INFO"
Write-Log "" -Level "STEP"
Write-Log "VERIFICATION RAPIDE :" -Level "STEP"
Write-Log "  claude --version          # Version installee" -Level "INFO"
Write-Log "  claude doctor             # Diagnostic complet" -Level "INFO"
Write-Log "  claude `"Bonjour!`"         # Test rapide" -Level "INFO"
Write-Log "" -Level "STEP"

exit 0
