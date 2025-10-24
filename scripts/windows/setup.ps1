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

function New-RandomSecret {
    param([int]$Bytes = 48)
    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    $secret = [Convert]::ToBase64String($buffer)
    $secret = $secret.TrimEnd('=').Replace('+','-').Replace('/','_')
    return $secret
}

function Ensure-Cursor {
    Write-Section "Ensuring Cursor editor is installed"
    try {
        Ensure-Winget
    } catch {
        Write-Warning "Unable to verify winget availability ($_). Install Cursor manually from https://cursor.sh/download and rerun this script."
        return
    }

    $cursorId = "Cursor.Cursor"
    $cursorPath = Join-Path $env:LOCALAPPDATA "Programs\Cursor\Cursor.exe"
    $installed = $false
    try {
        $listOutput = winget list --id $cursorId --exact --accept-source-agreements 2>$null
        if ($LASTEXITCODE -eq 0 -and $listOutput -match [regex]::Escape($cursorId)) {
            $installed = $true
        }
    } catch {
        Write-Warning "winget list failed to detect Cursor ($_). Continuing with installation attempt."
    }

    if ($installed -and (Test-Path $cursorPath)) {
        Write-Host "Cursor already installed at $cursorPath."
        return
    }

    Write-Host "Installing Cursor editor via winget..."
    $arguments = @(
        "install", "-e", "--id", $cursorId,
        "--accept-package-agreements", "--accept-source-agreements"
    )
    $proc = Start-Process -FilePath "winget" -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    switch ($proc.ExitCode) {
        0 {
            if (Test-Path $cursorPath) {
                Write-Host "Cursor installation completed successfully at $cursorPath."
            } else {
                Write-Warning "Cursor installer reported success but $cursorPath was not found. Install Cursor manually from https://cursor.sh/download and rerun this script."
            }
        }
        3010 {
            Write-Warning "Cursor installation signaled a reboot requirement. Restart Windows to finish installation, then rerun this script if needed."
        }
        default {
            Write-Warning "Cursor installer exited with code $($proc.ExitCode). Install Cursor manually from https://cursor.sh/download if the editor is still missing."
        }
    }
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
    $outputLines = New-Object System.Collections.Generic.List[string]
    & wsl.exe @args 2>&1 | ForEach-Object {
        $line = [string]$_
        $outputLines.Add($line)
        Write-Host $line
    }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    $consoleOutput = if ($outputLines.Count -gt 0) {
        ($outputLines -join [Environment]::NewLine).TrimEnd()
    } else {
        ""
    }
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
        [string[]]$Hosts = @(
            'github.com',
            'raw.githubusercontent.com',
            'objects.githubusercontent.com',
            'download.docker.com',
            'aka.ms',
            'cursor.sh'
        ),
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

function Ensure-CloudBootstrap {
    param([string]$RepoSlug)

    Write-Section "Cloud account provisioning"
    $proceedInput = Read-Host "Configure Google Cloud authentication and GitHub environments now? [Y/n]"
    if ($proceedInput -match '^[Nn]') {
        return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $false }
    }

    $originUrl = git remote get-url origin 2>$null
    $defaultRepoSlug = $RepoSlug
    if ($originUrl -match 'github.com[:/](.+?)(\.git)?$') {
        $defaultRepoSlug = $matches[1]
    }

    $defaultProject = if ([string]::IsNullOrWhiteSpace($env:GCP_PROJECT_ID)) { ($defaultRepoSlug -split '/')[1] } else { $env:GCP_PROJECT_ID }
    $projectId = Read-Host "Enter GCP project ID [$defaultProject]"
    if ([string]::IsNullOrWhiteSpace($projectId)) { $projectId = $defaultProject }

    $defaultRegion = if ([string]::IsNullOrWhiteSpace($env:GCP_REGION)) { 'us-central1' } else { $env:GCP_REGION }
    $region = Read-Host "Enter default GCP region [$defaultRegion]"
    if ([string]::IsNullOrWhiteSpace($region)) { $region = $defaultRegion }

    $defaultBucket = "$projectId-tf-state"
    $bucket = Read-Host "Enter Terraform state bucket name [$defaultBucket]"
    if ([string]::IsNullOrWhiteSpace($bucket)) { $bucket = $defaultBucket }

    $repoTarget = Read-Host "Enter GitHub org/repo for hardening [$defaultRepoSlug]"
    if ([string]::IsNullOrWhiteSpace($repoTarget)) { $repoTarget = $defaultRepoSlug }

    $previousInfisical = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN', 'Process')
    $previousWslenv = [Environment]::GetEnvironmentVariable('WSLENV', 'Process')
    $generatedInfisical = $false

    try {
        Write-Section "Verifying GitHub repository access"
        $relayScript = @'
cat <<'EOFSCRIPT' >/tmp/open-in-windows.sh
#!/bin/bash
url="$1"
if [ -z "$url" ]; then
  read -r url
fi
if [ -n "$url" ]; then
  powershell.exe -Command "Start-Process \"${url}\""
fi
EOFSCRIPT
chmod +x /tmp/open-in-windows.sh
'@
        Invoke-Wsl -Command $relayScript *> $null
        $authReady = $false
        for ($attempt = 1; $attempt -le 5 -and -not $authReady; $attempt++) {
            $authStatus = Invoke-Wsl -Command "GH_BROWSER=/tmp/open-in-windows.sh gh auth status --hostname github.com"
            if ($authStatus.ExitCode -eq 0) {
                $authReady = $true
                break
            }

            Write-Host "Authenticating GitHub CLI inside WSL (attempt $attempt of 5)..." -ForegroundColor Yellow
            $authResult = Invoke-Wsl -Command "GH_BROWSER=/tmp/open-in-windows.sh gh auth login --hostname github.com --git-protocol https --web --scopes 'repo,workflow,admin:org'"
            if ($authResult.ExitCode -eq 0) {
                $authReady = $true
                break
            }

            $authOutput = ($authResult.Output | Out-String)
            if ($authOutput -match 'slow_down') {
                Write-Host "GitHub requested more time between login attempts. Retrying in 15 seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            } else {
                Write-Warning "Unable to authenticate GitHub CLI inside WSL. Run 'wsl -d $DistroName -- gh auth login --web' manually, then rerun this step."
                return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
            }
        }

        if (-not $authReady) {
            Write-Warning "GitHub CLI inside WSL could not be authenticated after multiple attempts."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        $repoView = Invoke-Wsl -Command "gh repo view $repoTarget --json name"
        if ($repoView.ExitCode -ne 0) {
            Write-Host "Repository '$repoTarget' not found. Creating it now..." -ForegroundColor Yellow
            Invoke-Wsl -Command "cd \$HOME/ai-dev-platform && git remote remove origin >/dev/null 2>&1 || true" *> $null
            $createCommands = @(
                "cd \$HOME/ai-dev-platform",
                "gh repo create $repoTarget --private --source \$HOME/ai-dev-platform --push --confirm --disable-wiki --disable-issues"
            )
            $createResult = Invoke-Wsl -Command ($createCommands -join '; ')
            if ($createResult.ExitCode -ne 0) {
                Write-Warning "Automatic repository creation failed; create $repoTarget manually and rerun."
                return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
            }
            Write-Host "Repository '$repoTarget' created and populated." -ForegroundColor Green
        }

        $repoAdminCheck = Invoke-Wsl -Command "gh api repos/$repoTarget --jq .permissions.admin"
        if ($repoAdminCheck.ExitCode -ne 0 -or $repoAdminCheck.Output.Trim().ToLower() -ne 'true') {
            Write-Warning "GitHub user lacks admin permissions on '$repoTarget'. Grant admin rights or choose a repository you administer, then rerun this step."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        $existingInf = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($existingInf)) {
            Write-Host "Reusing INFISICAL_TOKEN already present in the environment." -ForegroundColor Yellow
        } else {
            Write-Section "Infisical token"
            Write-Host "An INFISICAL_TOKEN is required for secret provisioning." -ForegroundColor Yellow
            $manualToken = Read-Host "Enter an existing INFISICAL_TOKEN (leave blank to generate one)"
            if (-not [string]::IsNullOrWhiteSpace($manualToken)) {
                [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN', $manualToken, 'Process')
            } else {
                Write-Host "Generating a new INFISICAL_TOKEN can incur Infisical subscription costs on paid plans." -ForegroundColor Yellow
                $confirm = Read-Host "Generate a strong INFISICAL_TOKEN automatically? [y/N]"
                if ($confirm -match '^[Yy]') {
                    $infToken = New-RandomSecret 48
                    Write-Section "Generated Infisical token"
                    Write-Host "INFISICAL_TOKEN: $infToken" -ForegroundColor Yellow
                    Write-Host "Store this token immediately in your password manager." -ForegroundColor Yellow
                    [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN', $infToken, 'Process')
                    $generatedInfisical = $true
                } else {
                    Write-Warning "Skipping Infisical token setup. Set INFISICAL_TOKEN and rerun cloud provisioning when ready."
                    return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $false }
                }
            }
            $wslenvParts = @()
            if (-not [string]::IsNullOrWhiteSpace($previousWslenv)) {
                $wslenvParts = $previousWslenv -split ';' | Where-Object { $_ -ne '' }
            }
            if ($wslenvParts -notcontains 'INFISICAL_TOKEN/p') {
                $wslenvParts += 'INFISICAL_TOKEN/p'
            }
            [Environment]::SetEnvironmentVariable('WSLENV', ($wslenvParts -join ';'), 'Process')
        }

        Write-Section "Google Cloud CLI authentication"
        Write-Host "Launching browser for gcloud login." -ForegroundColor Yellow
        $loginResult = Invoke-Wsl -Command "BROWSER='powershell.exe -Command Start-Process' gcloud auth login --launch-browser"
        if ($loginResult.ExitCode -ne 0) {
            Write-Warning "gcloud auth login failed (exit $($loginResult.ExitCode)). Complete authentication manually and rerun."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        $describeProject = Invoke-Wsl -Command "gcloud projects describe $projectId"
        if ($describeProject.ExitCode -ne 0) {
            Write-Warning "Project '$projectId' not found or access denied. Create it in the Google Cloud Console and rerun."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        Invoke-Wsl -Command "gcloud config set project $projectId" *> $null
        $billingStatus = Invoke-Wsl -Command "gcloud beta billing projects describe $projectId --format=value(billingEnabled)"
        if ($billingStatus.ExitCode -ne 0 -or $billingStatus.Output.Trim().ToLower() -ne 'true') {
            Write-Warning "Billing is not enabled for project '$projectId'. Enable billing in Google Cloud Console and rerun."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        $adcResult = Invoke-Wsl -Command "BROWSER='powershell.exe -Command Start-Process' gcloud auth application-default login --launch-browser"
        if ($adcResult.ExitCode -ne 0) {
            Write-Warning "gcloud application-default login failed; configure ADC manually and rerun."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        Write-Section "Terraform bootstrap"
        Write-Host "Using defaults; press Enter to accept when prompted." -ForegroundColor Yellow
        $bootstrapCommands = @(
            "export GCP_PROJECT_ID='$projectId'",
            "export GCP_REGION='$region'",
            "export GITHUB_ORG_REPO='$repoTarget'",
            "export TERRAFORM_STATE_BUCKET='$bucket'",
            "export STAGING_KSA_NAMESPACE='web'",
            "export STAGING_KSA_NAME='web-sa'",
            "export PRODUCTION_KSA_NAMESPACE='web'",
            "export PRODUCTION_KSA_NAME='web-sa'",
            "cd $HOME/ai-dev-platform",
            "./scripts/bootstrap-infra.sh"
        )
        $bootstrapResult = Invoke-Wsl -Command ($bootstrapCommands -join '; ')
        if ($bootstrapResult.ExitCode -ne 0) {
            Write-Warning "Infrastructure bootstrap exited with $($bootstrapResult.ExitCode). Review output above and rerun after addressing the issue."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        Write-Section "GitHub environment configuration"
        $configureCommands = @(
            "cd $HOME/ai-dev-platform",
            "./scripts/configure-github-env.sh staging",
            "./scripts/configure-github-env.sh prod"
        )
        $configureResult = Invoke-Wsl -Command ($configureCommands -join '; ')
        if ($configureResult.ExitCode -ne 0) {
            Write-Warning "configure-github-env.sh exited with $($configureResult.ExitCode). Rerun inside WSL after addressing the issue."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        Write-Host "Cloud authentication and environment configuration completed." -ForegroundColor Green
        return [PSCustomObject]@{ Completed = $true; GeneratedInfisical = $generatedInfisical }
    }
    finally {
        if ($generatedInfisical) {
            if ([string]::IsNullOrWhiteSpace($previousInfisical)) {
                [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN', $null, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN', $previousInfisical, 'Process')
            }
            [Environment]::SetEnvironmentVariable('WSLENV', $previousWslenv, 'Process')
        }
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
    $commands += 'export WINDOWS_AUTOMATED_SETUP=1'
    $commands += 'if [ -z "${SETUP_STATE_DIR:-}" ]; then SETUP_STATE_DIR="$HOME/.cache/ai-dev-platform/setup-state"; fi'
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

function Show-PostBootstrapChecklist {
    param(
        [bool]$CloudBootstrapCompleted,
        [bool]$GeneratedInfisical
    )
    Write-Section "Next steps"

    $cursorPath = Join-Path $env:LOCALAPPDATA "Programs\Cursor\Cursor.exe"
    if (Test-Path $cursorPath) {
        Write-Host "1. Launch Cursor and complete AI assistant sign-in:" -ForegroundColor Yellow
        Write-Host "   - GitHub account (prompted on first launch)." -ForegroundColor Yellow
        Write-Host "   - Command Palette → 'Codex: Sign In'." -ForegroundColor Yellow
        Write-Host "   - Command Palette → 'Claude Code: Sign In'." -ForegroundColor Yellow

        try {
            $launchPrompt = Read-Host "Open Cursor now to start sign-in? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($launchPrompt) -or $launchPrompt -match '^[Yy]') {
                Start-Process -FilePath $cursorPath | Out-Null
            }
        } catch {
            Write-Warning "Unable to launch Cursor automatically ($_)"
        }
    } else {
        Write-Warning "Cursor executable not detected. Install it from https://cursor.sh/download, then sign into Codex and Claude Code."
    }

    Write-Host "2. In WSL, run 'cd ~/ai-dev-platform && pnpm --filter @ai-dev-platform/web dev' to start coding." -ForegroundColor Yellow

    if ($CloudBootstrapCompleted) {
        Write-Host "3. Google Cloud authentication, Terraform bootstrap, and GitHub environments are configured." -ForegroundColor Green
        if ($GeneratedInfisical) {
            Write-Host "   Remember to store the generated INFISICAL_TOKEN securely." -ForegroundColor Yellow
        }
    } else {
        Write-Host "3. To configure cloud infrastructure later, run inside WSL:" -ForegroundColor Yellow
        Write-Host "   - gcloud auth login" -ForegroundColor Yellow
        Write-Host "   - gcloud auth application-default login" -ForegroundColor Yellow
        Write-Host "   - ./scripts/bootstrap-infra.sh" -ForegroundColor Yellow
        Write-Host "   - ./scripts/configure-github-env.sh staging" -ForegroundColor Yellow
        Write-Host "   - ./scripts/configure-github-env.sh prod" -ForegroundColor Yellow
        Write-Host "   (Generate an INFISICAL token if you rely on Infisical secrets.)" -ForegroundColor Yellow
    }

    Write-Host "4. Rerun './scripts/setup-all.sh' anytime to resume or verify the environment." -ForegroundColor Yellow
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
Ensure-Cursor

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

$cloudBootstrapContext = Ensure-CloudBootstrap -RepoSlug $RepoSlug
Show-PostBootstrapChecklist -CloudBootstrapCompleted:$cloudBootstrapContext.Completed -GeneratedInfisical:$cloudBootstrapContext.GeneratedInfisical

Write-Section "Bootstrap complete"
Write-Host "Open WSL (Ubuntu) and run 'cd ~/ai-dev-platform && pnpm --filter @ai-dev-platform/web dev' to start developing." -ForegroundColor Green
