Param(
    [string]$RepoSlug = "swb2019/ai-dev-platform",
    [string]$Branch = "main",
    [string]$DistroName = "Ubuntu",
    [switch]$SkipDockerInstall,
    [switch]$SkipSetupAll,
    [string]$DockerInstallerPath,
    [string]$WslUserName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (-not $DockerInstallerPath -and $env:DOCKER_DESKTOP_INSTALLER) {
    $DockerInstallerPath = $env:DOCKER_DESKTOP_INSTALLER
}

if ($DistroName.StartsWith("[") -or $DistroName.StartsWith("-")) {
    Write-Warning "Received DistroName '$DistroName'; resetting to 'Ubuntu'. Use -DistroName if you need a custom image."
    $DistroName = "Ubuntu"
}

$script:DistroName = $DistroName

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session (Run as Administrator)."
    }
}

function Ensure-Command {
    param(
        [string]$Name,
        [string]$InstallHint
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        if ($InstallHint) {
            throw "Required command '$Name' not found. $InstallHint"
        }
        throw "Required command '$Name' not found."
    }
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        return
    }
    $msg = @(
        "The Windows Package Manager (winget) is required but missing.",
        "Install it from the Microsoft Store (App Installer) and rerun this script."
    ) -join " "
    throw $msg
}

function Enable-WindowsFeatures {
    Write-Section "Enabling Windows features for WSL2"
    $features = @(
        "Microsoft-Windows-Subsystem-Linux",
        "VirtualMachinePlatform"
    )
    foreach ($feature in $features) {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature
        if ($state.State -eq "Enabled") {
            continue
        }
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart
        if ($result.RestartNeeded) {
            Write-Warning "A reboot is required to finish enabling $feature. Restart Windows, rerun this script."
            exit 1
        }
    }
    wsl --set-default-version 2 | Out-Null
    try {
        wsl --update | Out-Null
    } catch {
        Write-Warning "wsl --update failed (older Windows build?). Continuing."
    }
}

function Ensure-WslDistribution {
    param([string]$Name)
    Write-Section "Ensuring WSL distribution '$Name' is installed"
    $existing = (wsl.exe -l -q) -replace "`0",""
    if ($existing -contains $Name) {
        return
    }
    Write-Host "Installing $Name (this may take a few minutes)..."
    try {
        wsl.exe --install -d $Name
    } catch {
        throw "Unable to install WSL distribution '$Name'. Install it manually via Microsoft Store or 'wsl --install -d $Name', then rerun this script."
    }
    Write-Warning "Windows may require a reboot to finish installing $Name. Reboot, launch the $Name app once to create your UNIX user, then rerun this script."
    exit 1
}

function Ensure-WslDefault {
    param([string]$Name)
    Write-Section "Setting '$Name' as the default WSL distribution"
    try {
        wsl.exe -s $Name | Out-Null
    } catch {
        Write-Warning "Unable to set default WSL distribution to '$Name' ($($_.Exception.Message)). Continuing."
    }
}

function Ensure-WslInitialized {
    param([string]$Name)
    Write-Section "Initializing WSL distribution '$Name'"
    $initCommand = "-d $Name -- echo WSL_READY"
    $process = Start-Process -FilePath "wsl.exe" -ArgumentList $initCommand -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -eq 0) {
        return
    }
    Ensure-WslDefaultUser -Name $Name
    $process = Start-Process -FilePath "wsl.exe" -ArgumentList $initCommand -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "Unable to initialize WSL distribution '$Name'. Launch it manually, ensure it works, then rerun this script."
    }
}

function Invoke-Wsl {
    param(
        [string]$Command,
        [switch]$AsRoot
    )
    $prefix = "set -euo pipefail; $Command"
    $prefix = $prefix.Replace("`r","")
    $args = @("-d", $script:DistroName)
    if ($AsRoot) {
        $args += @("-u", "root")
    }
    $args += @("--", "bash", "-lc", $prefix)
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $buffer = & wsl.exe @args 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($buffer) {
        $buffer | ForEach-Object { Write-Host $_ }
    }
    $consoleOutput = ($buffer | Out-String).TrimEnd()
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $consoleOutput
    }
}

function Normalize-WslUserName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }
    $candidate = $Name.ToLowerInvariant()
    $candidate = ($candidate -replace '[^a-z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }
    if ($candidate.Length -gt 32) {
        $candidate = $candidate.Substring(0, 32)
    }
    return $candidate
}

function Ensure-JsonProperty {
    param(
        [psobject]$Parent,
        [string]$Name,
        $DefaultValue
    )
    if (-not $Parent) {
        throw "JSON parent object cannot be null."
    }
    if (-not ($Parent.PSObject.Properties.Name -contains $Name)) {
        $Parent | Add-Member -MemberType NoteProperty -Name $Name -Value $DefaultValue
    }
    return $Parent.PSObject.Properties[$Name].Value
}

function Get-PreferredWslUserName {
    if (-not [string]::IsNullOrWhiteSpace($WslUserName)) {
        $normalized = Normalize-WslUserName -Name $WslUserName
        if ($normalized) {
            return $normalized
        }
        Write-Warning "Supplied WslUserName '$WslUserName' is invalid after sanitization. Falling back to the Windows username."
    }
    $candidate = Normalize-WslUserName -Name $env:USERNAME
    if ($candidate) {
        return $candidate
    }
    return "wsluser"
}

function Ensure-WslDefaultUser {
    param([string]$Name)
    Write-Section "Configuring default user for WSL distribution '$Name'"
    $user = Get-PreferredWslUserName
    $bootstrap = @"
set -euo pipefail
user="$user"
if id "\$user" >/dev/null 2>&1; then
  exit 0
fi
useradd --create-home --shell /bin/bash "\$user"
usermod -aG sudo "\$user"
mkdir -p /etc/sudoers.d
echo "\$user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/\$user
chmod 440 /etc/sudoers.d/\$user
printf '[user]\ndefault=%s\n' "\$user" >/etc/wsl.conf
"@
    $result = Invoke-Wsl -Command $bootstrap -AsRoot
    if ($result.ExitCode -ne 0) {
        throw "Failed to configure WSL user (exit $($result.ExitCode))."
    }
    wsl.exe --terminate $Name | Out-Null
}

function Test-NetworkConnectivity {
    param(
        [string[]]$Hosts = @('github.com', 'download.docker.com', 'aka.ms'),
        [int]$Port = 443
    )
    Write-Section "Checking network connectivity"
    $failures = @()
    foreach ($targetHost in $Hosts) {
        try {
            if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
                $result = Test-NetConnection -ComputerName $targetHost -Port $Port -WarningAction SilentlyContinue
                if (-not $result.TcpTestSucceeded) {
                    throw "TCP test failed."
                }
            } else {
                Invoke-WebRequest -Uri "https://$targetHost" -Method Head -TimeoutSec 10 -UseBasicParsing | Out-Null
            }
        } catch {
            Write-Warning ("Unable to reach {0}:{1}. Ensure firewalls or proxies allow outbound HTTPS. Error: {2}" -f $targetHost, $Port, $_.Exception.Message)
            $failures += $targetHost
        }
    }
    if ($failures.Count -gt 0) {
        Write-Warning "Network connectivity issues detected. Automated downloads may fail until connectivity to the hosts above is restored."
    }
}

function Ensure-WslPackages {
    Write-Section "Installing base packages inside WSL"
    $cmd = @"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates curl build-essential python3 python3-pip unzip pkg-config
"@
    $result = Invoke-Wsl -Command $cmd -AsRoot
    if ($result.ExitCode -ne 0) {
        throw "Failed to install base packages in WSL (exit $($result.ExitCode))."
    }
}

function Install-DockerDesktopFromUrl {
    $uri = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $tempPath = [System.IO.Path]::GetTempPath()
    $installer = Join-Path $tempPath "DockerDesktopInstaller.exe"
    Write-Host "Downloading Docker Desktop from $uri..."
    $invokeParams = @{
        Uri             = $uri
        OutFile         = $installer
        UseBasicParsing = $true
    }
    if ($env:HTTPS_PROXY -or $env:HTTP_PROXY) {
        $proxy = $null
        if ($env:HTTPS_PROXY) {
            $proxy = $env:HTTPS_PROXY
        } elseif ($env:HTTP_PROXY) {
            $proxy = $env:HTTP_PROXY
        }
        if ($proxy) {
            $invokeParams["Proxy"] = $proxy
            $invokeParams["ProxyUseDefaultCredentials"] = $true
        }
    }
    try {
        Invoke-WebRequest @invokeParams
    } catch {
        throw "Failed to download Docker Desktop installer from $uri. Ensure outbound HTTPS access is allowed (respecting proxy env vars) or provide -DockerInstallerPath."
    }
    Write-Host "Launching Docker Desktop installer..."
    $proc = Start-Process -FilePath $installer -ArgumentList "install","--accept-license","--start-service" -Verb RunAs -PassThru -Wait
    return $proc.ExitCode
}

function Install-DockerDesktopFromPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Docker Desktop installer path '$Path' not found."
    }
    Write-Host "Launching Docker Desktop installer from $Path..."
    $proc = Start-Process -FilePath $Path -ArgumentList "install","--accept-license","--start-service" -Verb RunAs -PassThru -Wait
    return $proc.ExitCode
}

function Ensure-DockerDesktop {
    Write-Section "Preparing Docker Desktop"
    $dockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $dockerExe)) {
        if ($SkipDockerInstall) {
            throw "Docker Desktop not found and --SkipDockerInstall was supplied."
        }
        if ($DockerInstallerPath) {
            $localExit = Install-DockerDesktopFromPath -Path $DockerInstallerPath
            switch ($localExit) {
                0 { }
                3010 {
                    Write-Warning "Docker Desktop installer signaled a reboot requirement. Restart Windows, then rerun this script."
                    exit 1
                }
                default {
                    Write-Warning "Installer at $DockerInstallerPath exited with code $localExit; falling back to winget."
                }
            }
            if (Test-Path $dockerExe) {
                Write-Host "Docker Desktop installed from provided path."
            }
        }
        if (-not (Test-Path $dockerExe)) {
            Ensure-Winget
            Write-Host "Docker Desktop not detected. Installing via winget..."
            winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
            $wingetExit = $LASTEXITCODE
            switch ($wingetExit) {
                0 { }
                3010 {
                    Write-Warning "Docker Desktop installation requires a Windows restart. Reboot, then rerun this script."
                    exit 1
                }
                default {
                    Write-Warning "winget failed to install Docker Desktop (exit $wingetExit). Attempting direct installer download."
                    try {
                        $directExit = Install-DockerDesktopFromUrl
                    } catch {
                        if ($DockerInstallerPath) {
                            Write-Warning "Download failed: $($_.Exception.Message)"
                            $directExit = Install-DockerDesktopFromPath -Path $DockerInstallerPath
                        } else {
                            throw
                        }
                    }
                    switch ($directExit) {
                        0 {
                            Write-Warning "Docker Desktop installer completed. Ensure Docker Desktop launches successfully, then rerun this script if required."
                        }
                        3010 {
                            Write-Warning "Docker Desktop installer signaled a reboot requirement. Restart Windows, then rerun this script."
                            exit 1
                        }
                        default {
                            throw "Docker Desktop installer exited with code $directExit. Provide a valid installer via -DockerInstallerPath or install manually."
                        }
                    }
                }
            }
        }
        if (-not (Test-Path $dockerExe)) {
            throw "Docker Desktop installer completed but '$dockerExe' was not found. Verify the installation manually."
        }
    }

    $settingsPath = Join-Path $env:APPDATA "Docker\settings.json"
    $settings = [pscustomobject]@{}
    if (Test-Path $settingsPath) {
        try {
            $rawSettings = Get-Content $settingsPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($rawSettings)) {
                $settings = $rawSettings | ConvertFrom-Json
            }
        } catch {
            $settings = [pscustomobject]@{}
        }
    }

    if (-not $settings) { $settings = [pscustomobject]@{} }
    $settings.wslEngineEnabled = $true
    $settings.autoStart = $true
    $resources = Ensure-JsonProperty -Parent $settings -Name "resources" -Default ([pscustomobject]@{})
    $wslIntegration = Ensure-JsonProperty -Parent $resources -Name "wslIntegration" -Default ([pscustomobject]@{})
    $enabledDistros = Ensure-JsonProperty -Parent $wslIntegration -Name "enabledDistros" -Default @()
    if ($enabledDistros -eq $null) {
        $enabledDistros = @()
    } elseif ($enabledDistros -isnot [System.Collections.IList]) {
        $enabledDistros = @($enabledDistros)
    } else {
        $enabledDistros = @($enabledDistros | Where-Object { $_ })
    }
    if (-not ($enabledDistros -contains $DistroName)) {
        $enabledDistros += $DistroName
    }
    $wslIntegration.enabledDistros = $enabledDistros
    $wslIntegration.defaultDistro = $DistroName
    $settings.wslEngineEnabled = $true
    ($settings | ConvertTo-Json -Depth 10) | Set-Content -Path $settingsPath -Encoding UTF8

    Write-Host "Starting Docker Desktop..."
    Start-Process -FilePath $dockerExe | Out-Null

    Write-Host "Waiting for Docker daemon inside WSL..."
    $attempts = 0
    while ($attempts -lt 60) {
        $result = Invoke-Wsl -Command "docker info >/dev/null 2>&1"
        if ($result.ExitCode -eq 0) {
            return
        }
        Start-Sleep -Seconds 5
        $attempts++
    }
    throw "Docker Desktop did not become ready in time. Ensure it is running and WSL integration is enabled for '$DistroName', then rerun this script."
}

function Ensure-Repository {
    Write-Section "Cloning repository inside WSL"
    $cloneScript = @"
user_home=`$(getent passwd `$(whoami) | cut -d: -f6)
if [ -n "`$user_home" ]; then
  export HOME="`$user_home"
fi
if [ ! -d "`$HOME/ai-dev-platform/.git" ]; then
  git clone https://github.com/$RepoSlug.git "`$HOME/ai-dev-platform"
fi
cd "`$HOME/ai-dev-platform"
git fetch origin
git checkout $Branch
git pull --ff-only origin $Branch || true
"@
    $result = Invoke-Wsl -Command $cloneScript
    if ($result.ExitCode -ne 0) {
        throw "Failed to clone or update repository inside WSL (exit $($result.ExitCode))."
    }
}

function Get-WslEnvPrefix {
    $lines = @()
    if ($env:GH_TOKEN) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:GH_TOKEN))
        $lines += "export GH_TOKEN=\$(printf '%s' '$encoded' | base64 -d)"
    }
    if ($env:INFISICAL_TOKEN) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:INFISICAL_TOKEN))
        $lines += "export INFISICAL_TOKEN=\$(printf '%s' '$encoded' | base64 -d)"
    }
    if ($lines.Count -eq 0) {
        return ""
    }
    return ($lines -join "; ")
}

function Run-SetupAll {
    Write-Section "Running ./scripts/setup-all.sh"
    $envPrefix = Get-WslEnvPrefix
    $commands = @()
    if ($envPrefix) {
        $commands += $envPrefix
    }
    $commands += 'if [ -z "${SETUP_STATE_DIR:-}" ]; then SETUP_STATE_DIR="$HOME/.cache/ai-dev-platform/setup-state"; fi'
    $commands += 'trimmed="${SETUP_STATE_DIR%/}"'
    $commands += 'if [ -z "$trimmed" ]; then trimmed="$HOME/.cache/ai-dev-platform/setup-state"; fi'
    $commands += 'SETUP_STATE_DIR="$trimmed"'
    $commands += 'STATE_PARENT="${SETUP_STATE_DIR%/*}"'
    $commands += 'STATE_NAME="${SETUP_STATE_DIR##*/}"'
    $commands += 'if [ -z "$STATE_PARENT" ] || [ "$STATE_PARENT" = "." ] || [ "$STATE_PARENT" = "$SETUP_STATE_DIR" ]; then STATE_PARENT="$HOME/.cache/ai-dev-platform"; fi'
    $commands += 'if [ -z "$STATE_NAME" ] || [ "$STATE_NAME" = "." ]; then STATE_NAME="setup-state"; fi'
    $commands += 'SETUP_STATE_DIR="$STATE_PARENT/$STATE_NAME"'
    $commands += 'mkdir -p -- "$STATE_PARENT"'
    $commands += 'mkdir -p -- "$SETUP_STATE_DIR"'
    $commands += 'export SETUP_STATE_DIR'
    $commands += 'cd $HOME/ai-dev-platform'
    $commands += './scripts/setup-all.sh'
    $command = ($commands -join '; ')
    $result = Invoke-Wsl -Command $command
    if ($result.ExitCode -eq 0) {
        return
    }
    if ($result.ExitCode -eq 2) {
        throw "Setup halted because Docker was not ready. Ensure Docker Desktop is running and rerun this script."
    }
    throw "./scripts/setup-all.sh failed inside WSL (exit $($result.ExitCode)). Open the WSL shell and rerun the script manually for details."
}

function Prompt-OptionalToken {
    param(
        [string]$EnvName,
        [string]$PromptMessage
    )
    $current = [Environment]::GetEnvironmentVariable($EnvName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        return $false
    }
    $secure = Read-Host "$PromptMessage (press Enter to skip)" -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) {
        return $false
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $value = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ($value) {
        [Environment]::SetEnvironmentVariable($EnvName, $value, 'Process')
        return $true
    }
    return $false
}

Write-Section "Windows bootstrap for AI Dev Platform"
Test-NetworkConnectivity
Ensure-Administrator
Enable-WindowsFeatures
Ensure-WslDistribution -Name $DistroName
Ensure-WslDefault -Name $DistroName
Ensure-WslInitialized -Name $DistroName
Ensure-WslPackages

if (-not $SkipDockerInstall) {
    Ensure-DockerDesktop
}

Ensure-Repository

if (-not $SkipSetupAll) {
    $ghTokenAdded = Prompt-OptionalToken -EnvName "GH_TOKEN" -PromptMessage "Optional GitHub token to streamline gh auth"
    $infTokenAdded = Prompt-OptionalToken -EnvName "INFISICAL_TOKEN" -PromptMessage "Optional Infisical token"
    Run-SetupAll
    if ($ghTokenAdded) { Remove-Item -Path Env:GH_TOKEN -ErrorAction SilentlyContinue }
    if ($infTokenAdded) { Remove-Item -Path Env:INFISICAL_TOKEN -ErrorAction SilentlyContinue }
}

Write-Section "Bootstrap complete"
Write-Host "Open WSL (Ubuntu) and run 'cd ~/ai-dev-platform && pnpm --filter @ai-dev-platform/web dev' to start developing." -ForegroundColor Green
