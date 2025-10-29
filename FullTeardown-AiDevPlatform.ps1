<#
.SYNOPSIS
  Performs the most comprehensive AI Dev Platform teardown available from Windows PowerShell.

.DESCRIPTION
  Detects (or downloads) the repository, ensures WSL and Terraform prerequisites are satisfied,
  refreshes required credentials (Google Cloud CLI, Application Default Credentials, GitHub CLI,
  Infisical token), launches the Linux-side uninstall in WSL, removes Windows host tooling, deletes
  cached data, optionally deletes the GitHub fork, and verifies that no residual artefacts remain.

.PARAMETER SkipDestroyCloud
  Skip Terraform destroy (runs `./scripts/uninstall.sh --skip-destroy-cloud` instead of
  `--destroy-cloud`).

.PARAMETER SkipForkDeletion
  Do not offer to delete the GitHub repository linked to the local `origin` remote.

.PARAMETER SkipConfirm
  Suppress the final confirmation prompt before beginning the teardown.

.EXAMPLE
  PS> .\FullTeardown-AiDevPlatform.ps1

.EXAMPLE
  PS> .\FullTeardown-AiDevPlatform.ps1 -SkipDestroyCloud
#>
[CmdletBinding()]
param(
    [switch]$SkipDestroyCloud,
    [switch]$SkipForkDeletion,
    [switch]$SkipConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Convert-SecureStringToPlainText {
    param([System.Security.SecureString]$SecureString)
    if (-not $SecureString) { return "" }
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Run this teardown from an elevated PowerShell session."
    }
}

function Add-UniqueString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    foreach ($existing in $List) {
        if ($existing -ieq $Value) { return }
    }
    $List.Add($Value)
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return
    }
    foreach ($existing in $List) {
        if ($existing -ieq $full) { return }
    }
    $List.Add($full)
}

function Test-IsRepoRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } catch {
        return $false
    }
    $resetScript = Join-Path $resolved 'Reset-AiDevPlatform.ps1'
    $uninstallScript = Join-Path $resolved 'scripts\uninstall.sh'
    return (Test-Path -LiteralPath $resetScript) -and (Test-Path -LiteralPath $uninstallScript)
}

function Convert-WindowsPathToWsl {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved -match '^[A-Za-z]:\\') {
        $drive = $resolved.Substring(0,1).ToLowerInvariant()
        $rest  = $resolved.Substring(2).TrimStart('\') -replace '\\','/'
        return "/mnt/$drive/$rest"
    }
    return ($resolved -replace '\\','/')
}

function Escape-WslSingleQuote {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return ($Text -replace "'", "'\''")
}

function Test-WslOperational {
    try {
        & wsl.exe -l -q 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-WslDistributions {
    if (-not (Test-CommandAvailable 'wsl.exe')) { return @() }
    try {
        return (& wsl.exe -l -q 2>$null) | ForEach-Object { ($_ -replace "`0","").Trim() } | Where-Object { $_ }
    } catch {
        return @()
    }
}

function Ensure-WslReady {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )
    $status = [ordered]@{ Ready = $false; PendingReboot = $false }
    $wslExists = Test-CommandAvailable 'wsl.exe'
    if ($wslExists -and (Test-WslOperational)) {
        $status.Ready = $true
        return $status
    }

    $Notes.Add("WSL is not fully available; enabling Windows Subsystem for Linux and Virtual Machine Platform features.")
    foreach ($feature in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
        $output = & dism.exe /online /enable-feature /featurename:$feature /all /norestart 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 3010) {
            $status.PendingReboot = $true
        } elseif ($exitCode -ne 0) {
            $Issues.Add("dism.exe failed to enable feature '$feature' (exit $exitCode). Output: $($output -join ' ')")
            return $status
        }
    }

    if ($wslExists) {
        try {
            $installOutput = & wsl.exe --install -d Ubuntu --no-launch 2>&1
            if ($LASTEXITCODE -eq 0 -and ($installOutput -match 'restart' -or $installOutput -match 'Reboot')) {
                $status.PendingReboot = $true
            }
        } catch {
            $Notes.Add("Attempt to initialize WSL returned: $($_.Exception.Message)")
        }
    }

    if (Test-WslOperational) {
        $status.Ready = $true
    } elseif (-not $status.PendingReboot) {
        $Issues.Add("WSL is still unavailable after enabling features. Install WSL manually and rerun the teardown.")
    }
    return $status
}

function Acquire-AiDevRepo {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($envName in 'AI_DEV_PLATFORM_REPO','AI_DEV_PLATFORM_PATH','AI_DEV_PLATFORM_ROOT') {
        $value = [Environment]::GetEnvironmentVariable($envName,'Process')
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($envName,'User') }
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($envName,'Machine') }
        Add-UniqueString -List $candidates -Value $value
    }
    if ($MyInvocation.MyCommand.Path) {
        Add-UniqueString -List $candidates -Value (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    try {
        $pwdCandidate = (Get-Location).ProviderPath
        Add-UniqueString -List $candidates -Value $pwdCandidate
        $gitRoot = (& git -C $pwdCandidate rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitRoot) {
            Add-UniqueString -List $candidates -Value ($gitRoot.Trim())
        }
    } catch {}

    $userProfile = $env:UserProfile
    foreach ($path in @("$userProfile\ai-dev-platform","$userProfile\dev\ai-dev-platform","C:\dev\ai-dev-platform")) {
        Add-UniqueString -List $candidates -Value $path
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        try {
            Add-UniqueString -List $candidates -Value (Join-Path $drive.Root 'ai-dev-platform')
            Add-UniqueString -List $candidates -Value (Join-Path $drive.Root 'dev\ai-dev-platform')
            Add-UniqueString -List $candidates -Value (Join-Path $drive.Root "Users\$env:USERNAME\ai-dev-platform")
        } catch {}
    }

    foreach ($candidate in $candidates) {
        if (Test-IsRepoRoot $candidate) {
            $resolved = (Resolve-Path -LiteralPath $candidate).ProviderPath
            return [ordered]@{ Path = $resolved; Temporary = $false }
        }
    }

    $Notes.Add("Local repository not found. Downloading a fresh archive of ai-dev-platform.")
    $downloadRoot = Join-Path $env:ProgramData "ai-dev-platform\teardown-cache"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    $archivePath = Join-Path $downloadRoot "ai-dev-platform-main.zip"
    try {
        $protocols = [Net.ServicePointManager]::SecurityProtocol
        if (($protocols -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch {}
    $repoUrl = "https://github.com/swb2019/ai-dev-platform/archive/refs/heads/main.zip"
    try {
        Invoke-WebRequest -Uri $repoUrl -OutFile $archivePath -UseBasicParsing
    } catch {
        $Issues.Add("Failed to download repository archive from ${repoUrl}: $($_.Exception.Message)")
        return [ordered]@{ Path = $null; Temporary = $false }
    }
    try {
        Expand-Archive -Path $archivePath -DestinationPath $downloadRoot -Force
    } catch {
        $Issues.Add("Failed to extract repository archive ($archivePath): $($_.Exception.Message)")
        return [ordered]@{ Path = $null; Temporary = $false }
    }
    $extracted = Get-ChildItem -Path $downloadRoot -Directory | Where-Object { Test-IsRepoRoot $_.FullName } | Select-Object -First 1
    if (-not $extracted) {
        $Issues.Add("Repository archive extracted but the expected layout was not found under $downloadRoot.")
        return [ordered]@{ Path = $null; Temporary = $false }
    }
    return [ordered]@{ Path = (Resolve-Path -LiteralPath $extracted.FullName).ProviderPath; Temporary = $true }
}

function Ensure-TerraformAvailable {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )
    $command = Get-Command terraform.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $Notes.Add("Terraform CLI not found; downloading Terraform 1.6.6 for Windows.")
    $version = "1.6.6"
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'windows_arm64' } else { 'windows_amd64' }
    $downloadRoot = Join-Path $env:ProgramData "ai-dev-platform\terraform"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    $archivePath = Join-Path $downloadRoot "terraform_$version.zip"
    $uri = "https://releases.hashicorp.com/terraform/$version/terraform_${version}_${platform}.zip"
    try {
        Invoke-WebRequest -Uri $uri -OutFile $archivePath -UseBasicParsing
    } catch {
        $Issues.Add("Unable to download Terraform from ${uri}: $($_.Exception.Message)")
        return $null
    }
    try {
        Expand-Archive -Path $archivePath -DestinationPath $downloadRoot -Force
    } catch {
        $Issues.Add("Unable to extract Terraform archive ($archivePath): $($_.Exception.Message)")
        return $null
    }
    $terraformExe = Join-Path $downloadRoot "terraform.exe"
    if (-not (Test-Path -LiteralPath $terraformExe)) {
        $Issues.Add("Terraform executable not found after extraction at $terraformExe.")
        return $null
    }
    if ($env:PATH -notlike "*$downloadRoot*") {
        $env:PATH = "$downloadRoot;$env:PATH"
    }
    return $terraformExe
}

function Ensure-CredentialReadiness {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )

    if (Test-CommandAvailable 'gcloud') {
        $gcloudAccountOk = $false
        $gcloudLoginSkipped = $false
        try {
            $accounts = (& gcloud auth list --format=value(account) 2>$null)
            $gcloudAccountOk = [bool]$accounts
        } catch {
            $Issues.Add("Unable to query gcloud accounts: $($_.Exception.Message)")
            $accounts = @()
        }
        if (-not $gcloudAccountOk) {
            Write-Host "Google Cloud CLI is installed but no authenticated user is configured." -ForegroundColor Yellow
            $answer = Read-Host "Press Enter to launch 'gcloud auth login' now, or type 'skip' to leave it unset"
            $launchLogin = $true
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('skip','s')) {
                $launchLogin = $false
                $gcloudLoginSkipped = $true
                $Notes.Add("Skipped gcloud auth login; continuing with existing credentials.")
            }
            if ($launchLogin) {
                try {
                    & gcloud auth login --brief
                } catch {
                    $Issues.Add("gcloud auth login failed: $($_.Exception.Message)")
                }
                try {
                    $accounts = (& gcloud auth list --format=value(account) 2>$null)
                    $gcloudAccountOk = [bool]$accounts
                } catch {
                    $gcloudAccountOk = $false
                }
            }
        }
        if (-not $gcloudAccountOk) {
            if ($gcloudLoginSkipped) {
                $Notes.Add("Google Cloud CLI user authentication still missing; ensure Terraform destroy does not rely on it.")
            } else {
                $Issues.Add("Google Cloud CLI lacks an authenticated user. Run 'gcloud auth login' before rerunning the teardown.")
            }
        }

        $adcOk = $false
        $adcSkipped = $false
        try {
            & gcloud auth application-default print-access-token 2>$null
            $adcOk = ($LASTEXITCODE -eq 0)
        } catch {
            $adcOk = $false
        }
        if (-not $adcOk) {
            Write-Host "Google Application Default Credentials are missing." -ForegroundColor Yellow
            $answer = Read-Host "Press Enter to launch 'gcloud auth application-default login', or type 'skip' to leave it unset"
            $launchAdc = $true
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('skip','s')) {
                $launchAdc = $false
                $adcSkipped = $true
                $Notes.Add("Skipped gcloud application-default login; continuing without ADC refresh.")
            }
            if ($launchAdc) {
                try {
                    & gcloud auth application-default login
                } catch {
                    $Issues.Add("gcloud auth application-default login failed: $($_.Exception.Message)")
                }
                try {
                    & gcloud auth application-default print-access-token 2>$null
                    $adcOk = ($LASTEXITCODE -eq 0)
                } catch {
                    $adcOk = $false
                }
            }
        }
        if (-not $adcOk) {
            if ($adcSkipped) {
                $Notes.Add("Application Default Credentials still unavailable; Terraform destroy may fail if they are required.")
            } else {
                $Issues.Add("Application Default Credentials are still unavailable. Run 'gcloud auth application-default login' before rerunning the teardown.")
            }
        }
    } else {
        $Issues.Add("gcloud CLI not found on PATH; install Google Cloud SDK or provide credentials before rerunning the teardown.")
    }

    if (Test-CommandAvailable 'gh') {
        $ghOk = $false
        $ghSkipped = $false
        try {
            & gh auth status --hostname github.com 2>&1 | Out-Null
            $ghOk = ($LASTEXITCODE -eq 0)
        } catch {
            $ghOk = $false
        }
        if (-not $ghOk) {
            Write-Host "GitHub CLI is not authenticated for github.com." -ForegroundColor Yellow
            $answer = Read-Host "Press Enter to launch 'gh auth login --hostname github.com --web', or type 'skip' to continue without GitHub access"
            $launchGh = $true
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('skip','s')) {
                $launchGh = $false
                $ghSkipped = $true
                $Notes.Add("Skipped GitHub CLI login; continuing without refreshing GitHub credentials.")
            }
            if ($launchGh) {
                try {
                    & gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org"
                } catch {
                    $Issues.Add("gh auth login failed: $($_.Exception.Message)")
                }
                try {
                    & gh auth status --hostname github.com 2>&1 | Out-Null
                    $ghOk = ($LASTEXITCODE -eq 0)
                } catch {
                    $ghOk = $false
                }
            }
        }
        if (-not $ghOk) {
            if ($ghSkipped) {
                $Notes.Add("GitHub CLI authentication still missing; fork deletion and GitHub API actions may fail.")
            } else {
                $Issues.Add("GitHub CLI authentication required. Run 'gh auth login --hostname github.com' before rerunning the teardown.")
            }
        }
    } else {
        $Notes.Add("GitHub CLI not detected; skipping GitHub verification.")
    }
}

function Ensure-InfisicalToken {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )

    $existing = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN','Process')
    if (-not $existing) {
        $existing = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN','User')
    }
    if (-not $existing) {
        $existing = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN','Machine')
    }

    if ([string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "Infisical token not detected." -ForegroundColor Yellow
        Write-Host "If your Terraform workflows rely on Infisical-managed secrets, paste your INFISICAL_TOKEN now." -ForegroundColor Yellow
        Write-Host "Press Enter to paste the token securely; type 'skip' to continue without it." -ForegroundColor Yellow
        $response = Read-Host "INFISICAL_TOKEN"
        if ([string]::IsNullOrWhiteSpace($response)) {
            $secure = Read-Host "Paste INFISICAL_TOKEN" -AsSecureString
            $plain = Convert-SecureStringToPlainText $secure
        } elseif ($response.Trim().ToLowerInvariant() -in @('skip','s')) {
            $plain = ""
        } else {
            $plain = $response
        }
        if ([string]::IsNullOrWhiteSpace($plain)) {
            $Notes.Add("Proceeding without INFISICAL_TOKEN. Ensure Terraform destroy does not require Infisical secrets.")
        } else {
            [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN',$plain,[EnvironmentVariableTarget]::Process)
            $Notes.Add("INFISICAL_TOKEN loaded into the current session for teardown.")
        }
    } else {
        [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN',$existing,[EnvironmentVariableTarget]::Process)
        $Notes.Add("INFISICAL_TOKEN detected and loaded for teardown.")
    }
}

function Invoke-WslBlock {
    param(
        [string]$Script,
        [hashtable]$Environment = $null
    )
    $normalized = ($Script -replace "`r","").Trim()
    if ($Environment -and $Environment.Count -gt 0) {
        $exports = foreach ($item in $Environment.GetEnumerator()) {
            $escapedValue = Escape-WslSingleQuote $item.Value
            "export $($item.Key)='$escapedValue'"
        }
        $normalized = ($exports -join "`n") + "`n" + $normalized
    }
    $output = & wsl.exe -- bash -lc "$normalized" 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Stop-KnownProcesses {
    param([System.Collections.Generic.List[string]]$Issues)
    foreach ($serviceName in @('com.docker.service')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30)) | Out-Null
            } catch {
                $Issues.Add("Unable to stop service '$serviceName': $($_.Exception.Message)")
            }
        }
    }
    foreach ($name in @('Docker Desktop','DockerCli','com.docker.backend','com.docker.proxy','com.docker.service','Docker','dockerd','Cursor','cursor','node','wsl','wslhost')) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            try {
                $procs | Stop-Process -Force -ErrorAction Stop
            } catch {
                $Issues.Add("Unable to stop process '$name': $($_.Exception.Message)")
            }
        }
    }
}

function Remove-Tree {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$Issues,
        [int]$Attempts = 5
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $Attempts) {
                $Issues.Add("Failed to delete '$Path': $($_.Exception.Message)")
                break
            }
            Stop-KnownProcesses -Issues $Issues
            Start-Sleep -Seconds 2
        }
    }
    if (Test-Path -LiteralPath $Path) {
        $Issues.Add("Path still present after cleanup: $Path")
    }
}

function Ensure-WingetRemoved {
    param(
        [string]$PackageId,
        [string]$Label,
        [System.Collections.Generic.List[string]]$Issues
    )
    if ([string]::IsNullOrWhiteSpace($Label)) { return }
    $stillPresent = $false
    $wingetAvailable = Test-CommandAvailable 'winget'
    if ($wingetAvailable -and $PackageId) {
        try {
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $listing = winget list --id $PackageId 2>$null
                if (-not $listing -or $listing -notmatch [Regex]::Escape($PackageId)) { break }
                winget uninstall --id $PackageId --silent --accept-source-agreements --accept-package-agreements *> $null
                Start-Sleep -Seconds 5
            }
            $listing = winget list --id $PackageId 2>$null
            if ($listing -and $listing -match [Regex]::Escape($PackageId)) {
                $stillPresent = $true
            }
        } catch {
            $stillPresent = $true
            $Issues.Add("winget failed to remove ${Label}: $($_.Exception.Message)")
        }
    } else {
        $stillPresent = $true
    }
    if ($stillPresent) {
        try {
            $package = Get-Package -ProviderName Programs -Name $Label -ErrorAction SilentlyContinue
            if ($package) {
                Uninstall-Package -InputObject $package -Force -ErrorAction Stop
                $stillPresent = $false
            }
        } catch {
            $Issues.Add("Fallback uninstall for $Label failed: $($_.Exception.Message)")
            $stillPresent = $true
        }
    }
    if ($stillPresent) {
        $Issues.Add("$Label may still be installed. Remove it via Apps & Features if present.")
    }
}

function Ensure-WslDistroRemoved {
    param(
        [string]$Name,
        [System.Collections.Generic.List[string]]$Issues
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if (-not (Test-CommandAvailable 'wsl.exe')) { return }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $registered = Get-WslDistributions
        if ($registered -notcontains $Name) { return }
        try { & wsl.exe --terminate $Name 2>$null | Out-Null } catch {}
        try { & wsl.exe --unregister $Name 2>$null | Out-Null } catch {
            $Issues.Add("Failed to unregister WSL distribution '$Name': $($_.Exception.Message)")
        }
        Start-Sleep -Seconds 3
    }
    if ((Get-WslDistributions) -contains $Name) {
        $Issues.Add("WSL distribution '$Name' is still registered after multiple attempts.")
    }
}

function Invoke-HostCleanupIfPending {
    param(
        [string]$ScriptPath,
        [System.Collections.Generic.List[string]]$Issues
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return }
    Write-Host "Ensuring Windows host cleanup helper runs..." -ForegroundColor Cyan
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$ScriptPath,"-Elevated" -Verb RunAs -PassThru -ErrorAction Stop
        if ($proc) {
            $proc.WaitForExit(300000) | Out-Null
        }
    } catch {
        $Issues.Add("Unable to launch host cleanup script ($ScriptPath): $($_.Exception.Message)")
    }
    for ($i = 0; $i -lt 180; $i++) {
        if (-not (Test-Path -LiteralPath $ScriptPath)) { return }
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $ScriptPath) {
        $Issues.Add("Host cleanup script still present at $ScriptPath. Run it manually as administrator.")
    }
}

function Clear-EnvironmentVariables {
    param(
        [string[]]$Names,
        [System.Collections.Generic.List[string]]$Issues
    )
    foreach ($target in @([EnvironmentVariableTarget]::User,[EnvironmentVariableTarget]::Machine)) {
        foreach ($name in $Names) {
            try {
                [Environment]::SetEnvironmentVariable($name,$null,$target)
            } catch {
                $Issues.Add("Unable to clear environment variable ${name} for scope ${target}: $($_.Exception.Message)")
            }
        }
    }
}

function Verify-EnvironmentVariables {
    param(
        [string[]]$Names,
        [System.Collections.Generic.List[string]]$Issues
    )
    foreach ($target in @([EnvironmentVariableTarget]::User,[EnvironmentVariableTarget]::Machine)) {
        foreach ($name in $Names) {
            $value = [Environment]::GetEnvironmentVariable($name,$target)
            if ($value) {
                $Issues.Add("Environment variable $name still set for scope $target.")
            }
        }
    }
}

function Verify-DirectoriesGone {
    param(
        [string[]]$Paths,
        [System.Collections.Generic.List[string]]$Issues
    )
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-Path -LiteralPath $path) {
            $Issues.Add("Residual path detected: $path")
        }
    }
}

function Verify-WingetAbsent {
    param(
        [System.Collections.Hashtable[]]$PackageIds,
        [System.Collections.Generic.List[string]]$Issues
    )
    $wingetAvailable = Test-CommandAvailable 'winget'
    foreach ($entry in $PackageIds) {
        $id = $entry['Id']
        $label = $entry['Label']
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if ($wingetAvailable -and $id) {
            try {
                $listing = winget list --id $id 2>$null
                if ($listing -and $listing -match [Regex]::Escape($id)) {
                    $Issues.Add("$label still appears in winget package list.")
                    continue
                }
            } catch {
                $Issues.Add("winget verification for $label failed: $($_.Exception.Message)")
                continue
            }
        }
        try {
            $package = Get-Package -ProviderName Programs -Name $label -ErrorAction SilentlyContinue
            if ($package) {
                $Issues.Add("$label still appears in Apps & Features.")
            }
        } catch {
            $Issues.Add("Unable to verify Apps & Features entry for ${label}: $($_.Exception.Message)")
        }
    }
}

function Verify-WslDistrosAbsent {
    param(
        [string[]]$Names,
        [System.Collections.Generic.List[string]]$Issues
    )
    if (-not (Test-CommandAvailable 'wsl.exe')) { return }
    $registered = Get-WslDistributions
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($registered -contains $name) {
            $Issues.Add("WSL distribution '$name' still registered.")
        }
    }
}

function Save-TerraformSummary {
    param(
        [string]$WslPath,
        [string]$Destination,
        [System.Collections.Generic.List[string]]$Issues
    )
    if (-not (Test-CommandAvailable 'wsl.exe')) { return }
    $result = Invoke-WslBlock "if [ -f '$WslPath' ]; then cat '$WslPath'; fi"
    if ($result.ExitCode -ne 0) {
        $Issues.Add("Unable to read Terraform summary from WSL (exit $($result.ExitCode)).")
        return
    }
    if (-not $result.Output) { return }
    $content = ($result.Output -join "`n").Trim()
    if (-not $content) { return }
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Set-Content -Path $Destination -Value $content -Encoding UTF8
}

function Parse-TerraformSummary {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$Issues
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        $Issues.Add("Terraform teardown summary not found at $Path.")
        return
    }
    try {
        $entries = Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in $entries) {
            if ($entry.status -notin @('success','skipped')) {
                $Issues.Add("Terraform ${entry.environment} reported '${entry.status}' (${entry.message}).")
            }
        }
    } catch {
        $Issues.Add("Unable to parse Terraform summary at ${Path}: $($_.Exception.Message)")
    }
}

function Get-GitRemoteSlug {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Remote = "origin"
    )
    if (-not (Test-CommandAvailable "git")) {
        return ""
    }
    try {
        $url = & git -C $RepoPath remote get-url $Remote 2>$null
    } catch {
        return ""
    }
    if ([string]::IsNullOrWhiteSpace($url)) {
        return ""
    }
    $url = $url.Trim()
    $match = [Regex]::Match($url, "github\.com[:/](.+?)(\.git)?$")
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function Invoke-GitHubForkDeletion {
    param(
        [string]$OriginSlug,
        [string]$UpstreamSlug = "swb2019/ai-dev-platform",
        [switch]$SkipPrompt
    )

    if ([string]::IsNullOrWhiteSpace($OriginSlug)) {
        Write-Host "Git origin remote not detected; skipping GitHub repository deletion." -ForegroundColor DarkGray
        return
    }
    if ([string]::IsNullOrWhiteSpace($UpstreamSlug)) {
        $UpstreamSlug = "swb2019/ai-dev-platform"
    }
    if ($OriginSlug -eq $UpstreamSlug) {
        Write-Host "Origin remote matches upstream ($OriginSlug); skipping GitHub repository deletion." -ForegroundColor DarkGray
        return
    }
    if (-not (Test-CommandAvailable "gh")) {
        Write-Host "GitHub CLI not available; delete '$OriginSlug' manually if desired." -ForegroundColor Yellow
        return
    }

    if (-not $SkipPrompt) {
        Write-Host ""
        Write-Host "Detected GitHub repository '$OriginSlug' linked to this checkout (upstream: $UpstreamSlug)." -ForegroundColor Yellow
        $answer = Read-Host "Delete GitHub repository '$OriginSlug'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "y" }
        if ($answer.Trim().ToLowerInvariant() -notin @("y","yes")) {
            Write-Host "Skipped deletion of GitHub repository '$OriginSlug'." -ForegroundColor DarkGray
            return
        }
    }

    try {
        & gh repo view $OriginSlug --json name 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "GitHub repository '$OriginSlug' not found or inaccessible; skipping deletion." -ForegroundColor DarkGray
            return
        }
    } catch {
        Write-Warning ("Unable to verify GitHub repository '{0}': {1}" -f $OriginSlug, $_.Exception.Message)
        return
    }

    try {
        & gh repo delete $OriginSlug --yes
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Deleted GitHub repository '$OriginSlug'." -ForegroundColor Green
        } else {
            Write-Warning ("gh repo delete '{0}' returned exit code {1}." -f $OriginSlug, $LASTEXITCODE)
        }
    } catch {
        Write-Warning ("Failed to delete GitHub repository '{0}': {1}" -f $OriginSlug, $_.Exception.Message)
    }
}

# --- Script execution starts here ---

Assert-Administrator

if (-not $SkipConfirm) {
    Write-Host "This will remove repository artefacts, tear down cloud resources, and delete the Windows tooling." -ForegroundColor Yellow
    $response = Read-Host "Continue? [Y/n]"
    if ($response -and $response.Trim() -notmatch '^(y|yes)$') {
        Write-Host "Aborted by user."
        return
    }
}

$initialPath = (Get-Item -LiteralPath '.' -ErrorAction Stop).FullName
$locationPushed  = $false

$issues = [System.Collections.Generic.List[string]]::new()
$notes  = [System.Collections.Generic.List[string]]::new()
$temporaryRoots = [System.Collections.Generic.List[string]]::new()

try {
$repoInfo = Acquire-AiDevRepo -Notes $notes -Issues $issues
if (-not $repoInfo.Path) {
    throw "Unable to locate or download the ai-dev-platform checkout. Resolve the issues above and rerun the teardown."
}
$repoRoot = $repoInfo.Path
if ($repoInfo.Temporary) {
    $temporaryRoots.Add($repoRoot)
    $notes.Add("Using a temporary archive of ai-dev-platform downloaded to $repoRoot.")
} else {
    $notes.Add("Using repository at $repoRoot")
}

$originSlug   = Get-GitRemoteSlug -RepoPath $repoRoot -Remote "origin"
$upstreamSlug = Get-GitRemoteSlug -RepoPath $repoRoot -Remote "upstream"
if ([string]::IsNullOrWhiteSpace($upstreamSlug)) {
    $upstreamSlug = "swb2019/ai-dev-platform"
}

$wslStatus = Ensure-WslReady -Notes $notes -Issues $issues
if (-not $wslStatus.Ready) {
    if ($wslStatus.PendingReboot) {
        throw "WSL features were enabled. Reboot Windows, then rerun this script to finish the teardown."
    }
    throw "WSL is unavailable; cannot proceed with the full teardown."
}

$terraformPath = Ensure-TerraformAvailable -Notes $notes -Issues $issues
if ($terraformPath) {
    $terraformDir = Split-Path -Parent $terraformPath
    if ($env:PATH -notlike "*$terraformDir*") {
        $env:PATH = "$terraformDir;$env:PATH"
    }
}

Ensure-CredentialReadiness -Notes $notes -Issues $issues
Ensure-InfisicalToken      -Notes $notes -Issues $issues

$summaryCopy = Join-Path $env:ProgramData "ai-dev-platform\uninstall-summary.json"
$hostScript  = "C:\ProgramData\ai-dev-platform\uninstall-host.ps1"
$wslSummary  = "/tmp/ai-dev-platform-uninstall-summary.json"
if (Test-Path -LiteralPath $summaryCopy) { Remove-Item $summaryCopy -Force }

Stop-KnownProcesses -Issues $issues

$repoParent = Split-Path -Parent $repoRoot
if ($repoParent -and (Test-Path -LiteralPath $repoParent)) {
    Push-Location -LiteralPath $repoParent
    $locationPushed = $true
}

$wslPath = Convert-WindowsPathToWsl $repoRoot
if ([string]::IsNullOrWhiteSpace($wslPath)) {
    $issues.Add("Unable to translate repository path '$repoRoot' into a WSL mount.")
} else {
    $sanitizeScript = @"
set -e
cd '$wslPath'
if command -v find >/dev/null 2>&1; then
  find . -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
fi
"@
    $sanitized = Invoke-WslBlock $sanitizeScript
    if ($sanitized.ExitCode -ne 0 -and $sanitized.Output) {
        $notes.Add("Shell script normalization reported: $($sanitized.Output -join ' ')")
    }

    $wslScript = @"
set -euo pipefail
cd '$wslPath'
rm -f '$wslSummary'
./scripts/uninstall.sh --full-reset --force {{DESTROY_FLAG}}
if [ -f uninstall-terraform-summary.json ]; then
  cp uninstall-terraform-summary.json '$wslSummary'
fi
"@
    $destroyFlag = if ($SkipDestroyCloud) { "--skip-destroy-cloud" } else { "--destroy-cloud" }
    $wslScript = $wslScript.Replace("{{DESTROY_FLAG}}", $destroyFlag)

    Write-Host "Executing teardown inside WSL..." -ForegroundColor Cyan
    $result = Invoke-WslBlock $wslScript
    if ($result.Output) {
        $result.Output | ForEach-Object { Write-Host $_ }
    }
    if ($result.ExitCode -ne 0) {
        $issues.Add("WSL uninstall script exited with code $($result.ExitCode).")
    } else {
        Save-TerraformSummary -WslPath $wslSummary -Destination $summaryCopy -Issues $issues
    }
}

Invoke-HostCleanupIfPending -ScriptPath $hostScript -Issues $issues

if (-not $SkipForkDeletion) {
    Invoke-GitHubForkDeletion -OriginSlug $originSlug -UpstreamSlug $upstreamSlug
}

Stop-KnownProcesses -Issues $issues

$pathsToRemove = [System.Collections.Generic.List[string]]::new()
foreach ($path in @(
    $repoRoot,
    "C:\dev\ai-dev-platform",
    "$env:UserProfile\ai-dev-platform",
    "$env:ProgramData\ai-dev-platform",
    "$env:ProgramData\ai-dev-platform\teardown-cache",
    "$env:ProgramData\ai-dev-platform\terraform",
    "$env:LOCALAPPDATA\ai-dev-platform",
    "$env:LOCALAPPDATA\Programs\Cursor",
    "$env:LOCALAPPDATA\Cursor",
    "$env:APPDATA\Cursor",
    "$env:UserProfile\.cursor",
    "$env:UserProfile\.codex",
    "$env:UserProfile\.cache\Cursor",
    "$env:UserProfile\.cache\ms-playwright",
    "$env:UserProfile\.cache\ai-dev-platform",
    "$env:UserProfile\.pnpm-store",
    "$env:UserProfile\.turbo",
    "$env:UserProfile\.npm",
    "$env:UserProfile\AppData\Local\Docker",
    "$env:UserProfile\AppData\Roaming\Docker",
    "$env:ProgramData\DockerDesktop",
    "$env:ProgramData\Docker",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Docker Desktop.lnk",
    "$env:UserProfile\Desktop\Docker Desktop.lnk",
    "$env:Public\Desktop\Docker Desktop.lnk"
)) {
    Add-UniquePath -List $pathsToRemove -Path $path
}

foreach ($path in $pathsToRemove) {
    Remove-Tree -Path $path -Issues $issues -Attempts 5
}

Clear-EnvironmentVariables -Names @('INFISICAL_TOKEN','GH_TOKEN','WSLENV','DOCKER_CERT_PATH','DOCKER_HOST','DOCKER_DISTRO_NAME') -Issues $issues

foreach ($pkg in @(
    @{ Id = 'Cursor.Cursor';            Label = 'Cursor' },
    @{ Id = 'Docker.DockerDesktop';     Label = 'Docker Desktop' },
    @{ Id = 'Docker.DockerDesktop.App'; Label = 'Docker Desktop App' },
    @{ Id = 'Docker.DockerDesktopEdge'; Label = 'Docker Desktop Edge' }
)) {
    Ensure-WingetRemoved -PackageId $pkg.Id -Label $pkg.Label -Issues $issues
}

$distroCandidates = [System.Collections.Generic.List[string]]::new()
foreach ($name in @('ai-dev-platform','Ubuntu-22.04-ai-dev-platform','Ubuntu-20.04-ai-dev-platform','Ubuntu-22.04','Ubuntu-24.04','Ubuntu')) {
    Add-UniqueString -List $distroCandidates -Value $name
}
foreach ($scope in @([EnvironmentVariableTarget]::User,[EnvironmentVariableTarget]::Machine)) {
    $value = [Environment]::GetEnvironmentVariable('DOCKER_DISTRO_NAME',$scope)
    Add-UniqueString -List $distroCandidates -Value $value
}
foreach ($name in Get-WslDistributions) {
    if ($name -match 'ai-dev' -or $name -match 'ubuntu') {
        Add-UniqueString -List $distroCandidates -Value $name
    }
}
foreach ($name in $distroCandidates) {
    Ensure-WslDistroRemoved -Name $name -Issues $issues
}

Stop-KnownProcesses -Issues $issues

Verify-DirectoriesGone      -Paths ($pathsToRemove.ToArray()) -Issues $issues
Verify-EnvironmentVariables -Names @('INFISICAL_TOKEN','GH_TOKEN','WSLENV','DOCKER_CERT_PATH','DOCKER_HOST','DOCKER_DISTRO_NAME') -Issues $issues
Verify-WingetAbsent         -PackageIds @(
    @{ Id = 'Cursor.Cursor';            Label = 'Cursor' },
    @{ Id = 'Docker.DockerDesktop';     Label = 'Docker Desktop' },
    @{ Id = 'Docker.DockerDesktop.App'; Label = 'Docker Desktop App' },
    @{ Id = 'Docker.DockerDesktopEdge'; Label = 'Docker Desktop Edge' }
) -Issues $issues
Verify-WslDistrosAbsent     -Names ($distroCandidates.ToArray()) -Issues $issues

if (Test-Path -LiteralPath $summaryCopy) {
    Parse-TerraformSummary -Path $summaryCopy -Issues $issues
} elseif (-not $SkipDestroyCloud) {
    $issues.Add("Terraform teardown summary not generated; confirm remote infrastructure manually.")
}

foreach ($tempRoot in $temporaryRoots) {
    try {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
        }
    } catch {
        $notes.Add("Temporary repository copy at '$tempRoot' could not be deleted automatically: $($_.Exception.Message)")
    }
}

if ($notes.Count -gt 0) {
    Write-Host ""
    Write-Host "Notes:" -ForegroundColor DarkCyan
    foreach ($note in $notes) {
        Write-Host " - $note"
    }
}

if ($issues.Count -eq 0) {
    Write-Host ""
    Write-Host "✅ Full teardown complete and verified. Reboot the machine to finish releasing Windows resources." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Warning "Cleanup verification found issues:"
    foreach ($issue in $issues) {
        Write-Host " - $issue" -ForegroundColor Yellow
    }
    throw "Automated reset finished with issues. Resolve the items above."
}
}
finally {
    if ($locationPushed) {
        try { Pop-Location | Out-Null } catch {}
    }
    if ($initialPath) {
        try { Set-Location -LiteralPath $initialPath } catch {}
    }
}
