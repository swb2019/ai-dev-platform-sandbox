Param(
    [string]$RepoSlug = "swb2019/ai-dev-platform",
    [string]$Branch = "main",
    [string]$DistroName = "Ubuntu",
    [switch]$SkipDockerInstall,
    [switch]$SkipSetupAll,
    [string]$DockerInstallerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:DistroName = $DistroName
if (-not $DockerInstallerPath -and $env:DOCKER_DESKTOP_INSTALLER) {
    $DockerInstallerPath = $env:DOCKER_DESKTOP_INSTALLER
}

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
    Write-Warning "WSL distribution '$Name' needs first-time setup. A new window will open; create your UNIX username and password, then exit."
    Start-Process -FilePath "wsl.exe" -ArgumentList "-d $Name" -Wait
    Read-Host "Press Enter after you have created the UNIX user and exited the WSL shell"
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
    $buffer = @()
    & wsl.exe @args 2>&1 | Tee-Object -Variable buffer
    $exitCode = $LASTEXITCODE
    $consoleOutput = ($buffer | Out-String).TrimEnd()
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $consoleOutput
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
    $settings = @{}
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        } catch {
            $settings = @{}
        }
    }

    if (-not $settings) { $settings = @{} }
    $settings.wslEngineEnabled = $true
    $settings.autoStart = $true
    if (-not $settings.ContainsKey("resources")) { $settings.resources = @{} }
    if (-not $settings.resources.ContainsKey("wslIntegration")) { $settings.resources.wslIntegration = @{} }
    $enabledDistros = @()
    if ($settings.resources.wslIntegration.ContainsKey("enabledDistros")) {
        $enabledDistros = @($settings.resources.wslIntegration.enabledDistros)
    }
    if (-not ($enabledDistros -contains $DistroName)) {
        $enabledDistros += $DistroName
    }
    $settings.resources.wslIntegration.enabledDistros = $enabledDistros
    $settings.resources.wslIntegration.defaultDistro = $DistroName
    $settings.wslEngineEnabled = $true
    $settings = [pscustomobject]$settings
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
if [ ! -d \$HOME/ai-dev-platform/.git ]; then
  git clone https://github.com/$RepoSlug.git \$HOME/ai-dev-platform
fi
cd \$HOME/ai-dev-platform
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
    $command = if ($envPrefix) { "$envPrefix; cd \$HOME/ai-dev-platform; ./scripts/setup-all.sh" } else { "cd \$HOME/ai-dev-platform; ./scripts/setup-all.sh" }
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
    $current = [Environment]::GetEnvironmentVariable($EnvName, "Process")
    if (-not [string]::IsNullOrEmpty($current)) {
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
        [Environment]::SetEnvironmentVariable($EnvName, $value, "Process")
        return $true
    }
    return $false
}

Write-Section "Windows bootstrap for AI Dev Platform"
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
