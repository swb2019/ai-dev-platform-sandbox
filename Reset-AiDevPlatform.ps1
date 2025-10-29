<#
.SYNOPSIS
  Runs the full AI Dev Platform uninstall from Windows PowerShell.

.DESCRIPTION
  Wrapper that invokes the existing Linux-side uninstall script inside WSL and
  triggers the Windows host cleanup. Use this when you want to reset a machine
  without opening a WSL shell manually.

.PARAMETER DryRun
  Show actions without deleting anything.

.PARAMETER DestroyCloud
  Run terraform destroy for each environment before removing local state.

.PARAMETER SkipConfirm
  Suppress the final confirmation message before running.

.EXAMPLE
  PS> .\Reset-AiDevPlatform.ps1

.EXAMPLE
  PS> .\Reset-AiDevPlatform.ps1 -DestroyCloud -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$DestroyCloud,
    [switch]$SkipConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Convert-WindowsPathToWsl {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved -match '^[A-Za-z]:\\') {
        $drive = $resolved.Substring(0,1).ToLowerInvariant()
        $rest = $resolved.Substring(2)
        $rest = $rest.TrimStart('\')
        $rest = $rest -replace '\\','/'
        return "/mnt/$drive/$rest"
    }
    return ($resolved -replace '\\','/')
}

function Invoke-DeferredDirectoryRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [int]$DelaySeconds = 5
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return
    }
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return
    }
    $escapedPath = $TargetPath -replace "'", "''"
    $script = @"
Start-Sleep -Seconds $DelaySeconds
if (Test-Path -LiteralPath '$escapedPath') {
    try {
        Remove-Item -LiteralPath '$escapedPath' -Recurse -Force -ErrorAction Stop
    } catch {
        Start-Sleep -Seconds 3
        try {
            Remove-Item -LiteralPath '$escapedPath' -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host ("Failed to remove '$escapedPath': {0}" -f `$_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand",$encoded -WindowStyle Hidden | Out-Null
    } catch {
        Write-Warning ("Failed to schedule deferred removal for '{0}': {1}" -f $TargetPath, $_.Exception.Message)
    }
}

function Invoke-RepositoryCleanup {
    param([string]$RepoPath)

    if ([string]::IsNullOrWhiteSpace($RepoPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $RepoPath)) {
        Write-Host ("Repository directory '{0}' already absent." -f $RepoPath) -ForegroundColor DarkGray
        return
    }

    $resolved = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
    $currentLocation = (Get-Location).ProviderPath
    if ($currentLocation) {
        try {
            if ($currentLocation.StartsWith($resolved, [System.StringComparison]::OrdinalIgnoreCase)) {
                $parent = Split-Path -LiteralPath $resolved -Parent
                if ([string]::IsNullOrWhiteSpace($parent)) {
                    $parent = [System.IO.Path]::GetPathRoot($resolved)
                }
                if (-not [string]::IsNullOrWhiteSpace($parent)) {
                    Set-Location -Path $parent
                    Write-Host ("Moved current directory to '{0}' to allow cleanup." -f $parent) -ForegroundColor DarkGray
                }
            }
        } catch {
            Write-Warning ("Unable to adjust working directory prior to cleanup: {0}" -f $_.Exception.Message)
        }
    }

    $removed = $false
    try {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        Write-Host ("Repository directory '{0}' removed." -f $resolved) -ForegroundColor Green
        $removed = $true
    } catch {
        Write-Warning ("Immediate removal failed for '{0}': {1}" -f $resolved, $_.Exception.Message)
    }

    if (-not $removed) {
        Invoke-DeferredDirectoryRemoval -TargetPath $resolved -DelaySeconds 6
        Write-Host ("Repository directory '{0}' queued for deferred deletion." -f $resolved) -ForegroundColor Yellow
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
        [string]$UpstreamSlug = "swb2019/ai-dev-platform"
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

    Write-Host ""
    Write-Host "Detected GitHub repository '$OriginSlug' linked to this checkout (upstream: $UpstreamSlug)." -ForegroundColor Yellow
    $answer = Read-Host "Delete GitHub repository '$OriginSlug'? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        $answer = "y"
    }
    if ($answer.Trim().ToLowerInvariant() -notin @("y","yes")) {
        Write-Host "Skipped deletion of GitHub repository '$OriginSlug'." -ForegroundColor DarkGray
        return
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

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "WSL is not installed or wsl.exe cannot be found. Install/enable WSL before running the reset."
}

$repoRoot = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { Get-Location }
$repoRoot = (Resolve-Path $repoRoot).ProviderPath

$uninstallScript = Join-Path $repoRoot "scripts\uninstall.sh"
if (-not (Test-Path $uninstallScript)) {
    throw "Unable to locate scripts\uninstall.sh under $repoRoot. Run this script from the repository checkout."
}

$wslPath = Convert-WindowsPathToWsl $repoRoot
if ([string]::IsNullOrWhiteSpace($wslPath)) {
    throw "Failed to translate $repoRoot into a WSL path. Ensure the WSL distribution is installed and running."
}
$wslPath = ($wslPath -replace "`r","").Trim()

$originSlug = Get-GitRemoteSlug -RepoPath $repoRoot -Remote "origin"
$upstreamSlug = Get-GitRemoteSlug -RepoPath $repoRoot -Remote "upstream"
if ([string]::IsNullOrWhiteSpace($upstreamSlug)) {
    $upstreamSlug = "swb2019/ai-dev-platform"
}

$commandArgs = [System.Collections.Generic.List[string]]::new()
$commandArgs.Add("./scripts/uninstall.sh")
$commandArgs.Add("--full-reset")
$commandArgs.Add("--force")
if ($DryRun)        { $commandArgs.Add("--dry-run") }
if ($DestroyCloud)  { $commandArgs.Add("--destroy-cloud") }
else                { $commandArgs.Add("--skip-destroy-cloud") }

$commandString = [string]::Join(" ", $commandArgs)

$escapeSingleQuote = { param($text) $text -replace "'", "'\''" }
$wslPathEscaped = & $escapeSingleQuote $wslPath
$commandEscaped = & $escapeSingleQuote $commandString
$fullCommand = "cd '$wslPathEscaped' && $commandEscaped"
$fullCommand = $fullCommand -replace "`r",""

if (-not $SkipConfirm) {
    Write-Host "This will remove repository artifacts, cached data, and launch the Windows cleanup helper." -ForegroundColor Yellow
    $answer = Read-Host "Continue? [Y/n]"
    if ($answer -and $answer.Trim() -notmatch '^(y|yes)$') {
        Write-Host "Aborted by user."
        return
    }
}


$sanitizeCommand = @"
cd '$wslPathEscaped'
if command -v find >/dev/null 2>&1; then
  find . -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
fi
"@
$sanitizeCommand = $sanitizeCommand -replace "`r",""
& wsl.exe -- bash -lc $sanitizeCommand 2>$null | Out-Null

Write-Host "Executing uninstall inside WSL..." -ForegroundColor Cyan
& wsl.exe -- bash -lc "$fullCommand"
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "WSL uninstall script exited with code $exitCode. Review the output above for details."
}

if (-not $DryRun) {
    if (Test-CommandAvailable "gh") {
        Invoke-GitHubForkDeletion -OriginSlug $originSlug -UpstreamSlug $upstreamSlug
    }
    $originalLocation = Get-Location
    $locationPushed = $false
    try {
        $repoParent = Split-Path -LiteralPath $repoRoot -Parent
        if ($repoParent -and (Test-Path -LiteralPath $repoParent)) {
            Push-Location -LiteralPath $repoParent
            $locationPushed = $true
        }
        Invoke-RepositoryCleanup -RepoPath $repoRoot
    } finally {
        if ($locationPushed) {
            Pop-Location | Out-Null
        } elseif ($originalLocation) {
            try { Set-Location -LiteralPath $originalLocation.Path } catch {}
        }
    }
} else {
    Write-Host "Dry-run mode: skipping GitHub fork deletion and repository cleanup." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "WSL uninstall completed. Approve the Windows UAC prompt (if shown) to finish removing host applications." -ForegroundColor Green
