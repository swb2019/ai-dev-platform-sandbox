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

function Convert-WindowsPathToWsl {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved -match '^[A-Za-z]:\\') {
        $drive = $resolved.Substring(0,1).ToLowerInvariant()
        $rest = $resolved.Substring(2).Replace('\\','/')
        return ("/mnt/{0}/{1}" -f $drive, $rest).Replace('//','/')
    }
    return $resolved.Replace('\\','/')
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

$commandArgs = [System.Collections.Generic.List[string]]::new()
$commandArgs.Add("./scripts/uninstall.sh")
$commandArgs.Add("--full-reset")
$commandArgs.Add("--force")
if ($DryRun)      { $commandArgs.Add("--dry-run") }
if ($DestroyCloud) { $commandArgs.Add("--destroy-cloud") }

$commandString = [string]::Join(" ", $commandArgs)

$escapeSingleQuote = { param($text) $text -replace "'", "'\''" }
$wslPathEscaped = & $escapeSingleQuote $wslPath
$commandEscaped = & $escapeSingleQuote $commandString
$fullCommand = "cd '$wslPathEscaped' && $commandEscaped"

if (-not $SkipConfirm) {
    Write-Host "This will remove repository artifacts, cached data, and launch the Windows cleanup helper." -ForegroundColor Yellow
    $answer = Read-Host "Continue? [Y/n]"
    if ($answer -and $answer.Trim() -notmatch '^(y|yes)$') {
        Write-Host "Aborted by user."
        return
    }
}

Write-Host "Executing uninstall inside WSL..." -ForegroundColor Cyan
& wsl.exe -- bash -lc "$fullCommand"
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "WSL uninstall script exited with code $exitCode. Review the output above for details."
}

Write-Host ""
Write-Host "WSL uninstall completed. Approve the Windows UAC prompt (if shown) to finish removing host applications." -ForegroundColor Green
