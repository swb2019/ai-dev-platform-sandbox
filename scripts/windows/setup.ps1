Param(
    [string]$RepoSlug = "swb2019/ai-dev-platform",
    [string]$Branch = "main",
    [string]$DistroName = "Ubuntu",
    [switch]$SkipDockerInstall,
    [switch]$SkipSetupAll,
    [string]$DockerInstallerPath,
    [string]$CursorInstallerPath,
    [string]$WslUserName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:CursorInstallerContextReady = $false
$script:CursorInstallerCacheDir = $null
$script:CursorInstallerLogFile = $null
$script:CursorInstallerLogAdvertised = $false
if (-not $DockerInstallerPath -and $env:DOCKER_DESKTOP_INSTALLER) {
    $DockerInstallerPath = $env:DOCKER_DESKTOP_INSTALLER
}
if (-not $CursorInstallerPath -and $env:CURSOR_INSTALLER_PATH) {
    $CursorInstallerPath = $env:CURSOR_INSTALLER_PATH
}
if ($CursorInstallerPath) {
    try {
        $expandedCursorInstallerPath = [Environment]::ExpandEnvironmentVariables($CursorInstallerPath)
        if (-not [string]::IsNullOrWhiteSpace($expandedCursorInstallerPath)) {
            $CursorInstallerPath = $expandedCursorInstallerPath
        }
    } catch {
        # ignore expansion failures
    }
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

function Initialize-CursorInstallerContext {
    if ($script:CursorInstallerContextReady) {
        return
    }
    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $roots += Join-Path $env:ProgramData "ai-dev-platform"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $roots += Join-Path $env:LOCALAPPDATA "ai-dev-platform"
    }
    foreach ($root in $roots) {
        try {
            if (-not (Test-Path $root)) {
                New-Item -ItemType Directory -Path $root -Force | Out-Null
            }
            $cursorCache = Join-Path $root "cursor"
            if (-not (Test-Path $cursorCache)) {
                New-Item -ItemType Directory -Path $cursorCache -Force | Out-Null
            }
            $script:CursorInstallerCacheDir = $cursorCache
            $script:CursorInstallerLogFile = Join-Path $root "cursor-install.log"
            $script:CursorInstallerMetadataPath = Join-Path $root "cursor-installer.json"
            $script:CursorInstallerContextReady = $true
            break
        } catch {
            continue
        }
    }
    if (-not $script:CursorInstallerContextReady) {
        $script:CursorInstallerCacheDir = $null
        $script:CursorInstallerLogFile = $null
        $script:CursorInstallerMetadataPath = $null
    }
}

function Write-CursorLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }
    Initialize-CursorInstallerContext
    if (-not $script:CursorInstallerLogFile) {
        return
    }
    $timestamp = [DateTime]::UtcNow.ToString("o")
    $entry = "{0} {1}" -f $timestamp, $Message
    try {
        Add-Content -Path $script:CursorInstallerLogFile -Value $entry -Encoding UTF8
    } catch {
        # ignore logging failures
    }
}

function Ensure-CursorLogAdvertised {
    if ($script:CursorInstallerLogAdvertised) {
        return
    }
    if ($script:CursorInstallerLogFile) {
        Write-Host ("Cursor installer diagnostics will be written to: {0}" -f $script:CursorInstallerLogFile) -ForegroundColor DarkCyan
        Write-CursorLog "Cursor installer log path advertised to user."
        $script:CursorInstallerLogAdvertised = $true
    }
}

function Get-CursorInstallerCachePath {
    param([string]$Version)
    Initialize-CursorInstallerContext
    if (-not $script:CursorInstallerCacheDir) {
        return $null
    }
    $safeSegment = "latest"
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $trimmed = $Version.Trim()
        $invalid = [IO.Path]::GetInvalidFileNameChars()
        $safeChars = $trimmed.ToCharArray() | ForEach-Object {
            if ($invalid -contains $_) { '_' } else { $_ }
        }
        $candidate = (-join $safeChars).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $safeSegment = $candidate.TrimStart('v','V')
        }
    }
    $fileName = "CursorSetup-{0}.exe" -f $safeSegment
    return Join-Path $script:CursorInstallerCacheDir $fileName
}

function Get-CursorInstallerMetadata {
    Initialize-CursorInstallerContext
    $path = $script:CursorInstallerMetadataPath
    if (-not $path -or -not (Test-Path $path)) {
        return $null
    }
    try {
        $content = Get-Content -Path $path -ErrorAction Stop -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }
        $data = $content | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.DownloadUrl) {
            return $null
        }
        return $data
    } catch {
        Write-CursorLog ("Failed to read Cursor installer metadata: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Save-CursorInstallerMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Info
    )

    Initialize-CursorInstallerContext
    $path = $script:CursorInstallerMetadataPath
    if (-not $path) {
        return
    }

    try {
        $payload = [pscustomobject]@{
            DownloadUrl = $Info.DownloadUrl
            FileName    = $Info.FileName
            Version     = $Info.Version
            SavedAtUtc  = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json -Depth 3
        Set-Content -Path $path -Value $payload -Encoding UTF8
        Write-CursorLog ("Cursor installer metadata saved to {0}" -f $path)
    } catch {
        Write-CursorLog ("Failed to persist Cursor installer metadata: {0}" -f $_.Exception.Message)
    }
}

function Test-CursorInstallerSignature {
    param([string]$Path)
    try {
        $signature = Get-AuthenticodeSignature -FilePath $Path
    } catch {
        Write-CursorLog ("Failed to evaluate installer signature for {0}: {1}" -f $Path, $_.Exception.Message)
        Write-Warning "Could not validate the Cursor installer signature at '$Path' ($($_.Exception.Message))."
        return $false
    }
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "unknown" }
    Write-CursorLog ("Signature status for {0}: {1} (subject: {2})" -f $Path, $signature.Status, $subject)
    if ($signature.Status -eq 'Valid') {
        return $true
    }
    if ($signature.Status -eq 'UnknownError') {
        Write-Warning "Cursor installer signature at '$Path' returned status 'UnknownError'. Continuing, but verify trust manually."
        return $true
    }
    Write-Warning "Cursor installer at '$Path' failed signature validation (status: $($signature.Status)). Install Cursor manually and rerun this script."
    return $false
}

function Get-CursorInstalledVersion {
    param([string]$Path)
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($info.ProductVersion -and -not [string]::IsNullOrWhiteSpace($info.ProductVersion)) {
            return $info.ProductVersion
        }
        if ($info.FileVersion -and -not [string]::IsNullOrWhiteSpace($info.FileVersion)) {
            return $info.FileVersion
        }
    } catch {
        Write-CursorLog ("Unable to determine Cursor version from {0}: {1}" -f $Path, $_.Exception.Message)
    }
    return $null
}

function Confirm-CursorInstallation {
    param(
        [string]$ExpectedVersion,
        [string]$ExpectedPath
    )
    $installPath = Get-CursorInstallPath
    if (-not $installPath) {
        Write-CursorLog "Cursor.exe not located after installer execution."
        return $false
    }
    $version = Get-CursorInstalledVersion -Path $installPath
    $displayVersion = if (-not [string]::IsNullOrWhiteSpace($version)) { $version } else { "unknown" }
    Write-CursorLog ("Detected Cursor installation at {0} (version: {1})" -f $installPath, $displayVersion)
    Write-Host ("Cursor detected at {0} (version: {1})." -f $installPath, $displayVersion)
    if ($ExpectedPath -and (-not (Test-Path $ExpectedPath))) {
        Write-Warning "Cursor installer completed, but '$ExpectedPath' was not created. Verify the installation manually."
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        return $true
    }
    $expected = $ExpectedVersion.TrimStart('v','V')
    $actual = if ($version) { $version.TrimStart('v','V') } else { $null }
    $expectedVersionObj = $null
    $actualVersionObj = $null
    try { $expectedVersionObj = [Version]$expected } catch { }
    try { $actualVersionObj = [Version]$actual } catch { }
    if ($expectedVersionObj -and $actualVersionObj -and $actualVersionObj -eq $expectedVersionObj) {
        return $true
    }
    if ($actual -and ($actual -eq $expected -or $actual.StartsWith($expected + ".") -or $expected.StartsWith($actual + "."))) {
        return $true
    }
    Write-Warning ("Cursor version mismatch. Expected '{0}', detected '{1}'. Re-run with a trusted installer or install manually." -f $ExpectedVersion, $displayVersion)
    return $false
}

function Invoke-CursorInstaller {
    param(
        [string]$InstallerPath,
        [string]$ExpectedVersion,
        [string]$ExpectedPath
    )
    Write-CursorLog ("Invoking Cursor installer at {0}" -f $InstallerPath)
    Write-Host "Running Cursor installer ($InstallerPath) in silent mode..."
    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList @("/S") -Wait -PassThru
    } catch {
        Write-CursorLog ("Cursor installer execution failed: {0}" -f $_.Exception.Message)
        Write-Warning "Cursor installer execution failed ($($_.Exception.Message))."
        return $false
    }
    if ($proc.ExitCode -ne 0) {
        Write-CursorLog ("Cursor installer exit code {0}" -f $proc.ExitCode)
        Write-Warning "Cursor installer exited with code $($proc.ExitCode)."
    }
    return Confirm-CursorInstallation -ExpectedVersion $ExpectedVersion -ExpectedPath $ExpectedPath
}

function Install-CursorFromPath {
    param(
        [string]$Path,
        [string]$ExpectedVersion,
        [string]$ExpectedInstallPath
    )
    $resolved = Resolve-CursorInstallerPath -Path $Path
    if (-not $resolved) {
        return $false
    }
    $cleanupPath = $resolved.Cleanup
    $installer = $resolved.Path
    Write-CursorLog ("Attempting Cursor installation from resolved path {0}" -f $installer)
    $result = $false
    try {
        if (-not (Test-CursorInstallerSignature -Path $installer)) {
            return $false
        }
        try {
            $hash = Get-FileHash -Path $installer -Algorithm SHA256
            Write-CursorLog ("Installer SHA256 hash: {0}" -f $hash.Hash)
        } catch {
            Write-CursorLog ("Unable to hash Cursor installer {0}: {1}" -f $installer, $_.Exception.Message)
        }
        $result = Invoke-CursorInstaller -InstallerPath $installer -ExpectedVersion $ExpectedVersion -ExpectedPath $ExpectedInstallPath
        return $result
    } finally {
        if ($cleanupPath -and (Test-Path $cleanupPath)) {
            try {
                Remove-Item $cleanupPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-CursorLog ("Cleaned up temporary installer artifacts at {0}" -f $cleanupPath)
            } catch {
                Write-CursorLog ("Failed to clean temporary installer folder {0}: {1}" -f $cleanupPath, $_.Exception.Message)
            }
        }
    }
}

function Resolve-CursorInstallerPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Warning "Cursor installer path was empty."
        return $null
    }
    if (-not (Test-Path $Path)) {
        Write-Warning "Cursor installer path '$Path' not found."
        Write-CursorLog ("Provided Cursor installer path not found: {0}" -f $Path)
        return $null
    }
    if (Test-Path $Path -PathType Leaf) {
        return [pscustomobject]@{ Path = (Get-Item -LiteralPath $Path).FullName; Cleanup = $null }
    }
    $resolvedFolder = $null
    $cleanupFolder = $null
    if (Test-Path $Path -PathType Container) {
        $resolvedFolder = (Get-Item -LiteralPath $Path).FullName
    }

    $extension = [IO.Path]::GetExtension($Path)
    if ($extension -and $extension.ToLowerInvariant() -eq ".zip") {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("cursor-installer-" + [guid]::NewGuid().ToString("N"))
        try {
            Expand-Archive -LiteralPath $Path -DestinationPath $tempDir -Force
            Write-CursorLog ("Expanded Cursor installer archive {0} to {1}" -f $Path, $tempDir)
            $resolvedFolder = $tempDir
            $cleanupFolder = $tempDir
        } catch {
            Write-Warning "Failed to extract Cursor installer archive '$Path' ($($_.Exception.Message))."
            Write-CursorLog ("Failed to expand archive {0}: {1}" -f $Path, $_.Exception.Message)
            if (Test-Path $tempDir) {
                try { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
            return $null
        }
    }

    if (-not $resolvedFolder) {
        Write-Warning "Cursor installer path '$Path' did not resolve to a file."
        Write-CursorLog ("Unable to resolve Cursor installer path: {0}" -f $Path)
        return $null
    }

    $candidates = Get-ChildItem -LiteralPath $resolvedFolder -Recurse -File | Where-Object {
        $_.Extension -match '\.exe$' -and $_.Name -match 'Cursor'
    } | Sort-Object LastWriteTime -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-Warning "Cursor installer path '$Path' did not contain a Cursor installer executable."
        Write-CursorLog ("No installer executables found under {0}" -f $resolvedFolder)
        if ($cleanupFolder) {
            try { Remove-Item $cleanupFolder -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        return $null
    }

    $selected = $candidates | Select-Object -First 1
    Write-CursorLog ("Resolved Cursor installer candidate {0} (LastWriteTime: {1})" -f $selected.FullName, $selected.LastWriteTime)
    return [pscustomobject]@{
        Path    = $selected.FullName
        Cleanup = $cleanupFolder
    }
}

function Get-CursorInstallPath {
    $candidates = @(
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Programs\Cursor\Cursor.exe"),
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Cursor\Cursor.exe")
    )
    $pf = $env:ProgramFiles
    if (-not [string]::IsNullOrWhiteSpace($pf)) {
        $candidates += Join-Path $pf "Cursor\Cursor.exe"
    }
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not [string]::IsNullOrWhiteSpace($pf86)) {
        $candidates += Join-Path $pf86 "Cursor\Cursor.exe"
    }
    foreach ($path in ($candidates | Where-Object { $_ -and (Test-Path $_) })) {
        return $path
    }
    try {
        $cmd = Get-Command "Cursor.exe" -ErrorAction Stop
        if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
            return $cmd.Source
        }
    } catch {
        # ignore lookup failures; we'll fall back to manual checks
    }
    return $null
}

function Get-CursorCliPath {
    param([string]$CursorExePath)

    $candidates = @()
    if ($CursorExePath) {
        $installRoot = Split-Path -Path $CursorExePath -Parent
        if ($installRoot) {
            $candidates += Join-Path $installRoot "resources\app\bin\cursor.exe"
            $candidates += Join-Path $installRoot "resources\app\bin\cursor.cmd"
            $candidates += Join-Path $installRoot "resources\app\bin\cursor"
            $candidates += Join-Path $installRoot "bin\cursor.exe"
            $candidates += Join-Path $installRoot "bin\cursor.cmd"
        }
    }

    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA "Cursor\bin\cursor.exe"
        $candidates += Join-Path $env:LOCALAPPDATA "Cursor\bin\cursor.cmd"
    }

    foreach ($candidate in ($candidates | Where-Object { $_ })) {
        try {
            if (Test-Path $candidate) {
                return $candidate
            }
        } catch { }
    }

    return $CursorExePath
}

function Get-CursorInstallerDownloadInfo {
    $headers = @{
        "User-Agent" = "ai-dev-platform-bootstrap"
        "Accept"     = "application/vnd.github+json"
    }
    $token = $null
    foreach ($candidate in @($env:GH_TOKEN, $env:GITHUB_TOKEN)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $token = $candidate
            break
        }
    }
    if ($token) {
        $headers["Authorization"] = "Bearer $token"
    }

    $invokeParams = @{
        Uri         = "https://api.github.com/repos/cursor/cursor/releases/latest"
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    $proxy = $null
    foreach ($candidateProxy in @($env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY)) {
        if (-not [string]::IsNullOrWhiteSpace($candidateProxy)) {
            $proxy = $candidateProxy
            break
        }
    }
    if ($proxy) {
        $invokeParams["Proxy"] = $proxy
        $invokeParams["ProxyUseDefaultCredentials"] = $true
    }

    $resolvedInfo = $null
    try {
        $release = Invoke-RestMethod @invokeParams
    } catch {
        Write-Warning ("Unable to query Cursor releases from GitHub API ({0}). Attempting cursor.com download manifest instead." -f $_.Exception.Message)
        Write-CursorLog ("GitHub release lookup failed: {0}" -f $_.Exception.Message)
        $release = $null
    }

    if ($release -and $release.assets) {
        $assets = @($release.assets)
        $preferred = $assets | Where-Object { $_.browser_download_url -match 'CursorSetup\.exe$' } | Select-Object -First 1
        if (-not $preferred) {
            $preferred = $assets | Where-Object { $_.browser_download_url -match '\.exe$' } | Select-Object -First 1
        }
        if ($preferred) {
            $fileName = if ($preferred.name) { $preferred.name } else { "CursorSetup.exe" }
            $version = if ($release.tag_name) { $release.tag_name } elseif ($release.name) { $release.name } else { $null }
            $versionDisplay = if (-not [string]::IsNullOrWhiteSpace($version)) { $version } else { "unknown" }
            Write-CursorLog ("Cursor release resolved from GitHub API (version: {0}, asset: {1})" -f $versionDisplay, $preferred.browser_download_url)
            $resolvedInfo = [pscustomobject]@{
                DownloadUrl = $preferred.browser_download_url
                FileName    = $fileName
                Version     = $version
            }
        } else {
            Write-CursorLog "Cursor release assets did not contain a recognizable Windows installer. Falling back to cursor.com manifest."
        }
    } else {
        Write-CursorLog "Cursor GitHub release metadata unavailable or missing assets; falling back to cursor.com manifest."
    }

    if (-not $resolvedInfo) {
        $resolvedInfo = Get-CursorInstallerDownloadInfoFromCursorSite
    }

    if ($resolvedInfo) {
        Save-CursorInstallerMetadata -Info $resolvedInfo
        return $resolvedInfo
    }

    $savedMetadata = Get-CursorInstallerMetadata
    if ($savedMetadata) {
        Write-Warning "Reusing previously saved Cursor installer information."
        Write-CursorLog ("Using cached Cursor installer metadata (version: {0}, url: {1})." -f $savedMetadata.Version, $savedMetadata.DownloadUrl)
        return $savedMetadata
    }

    foreach ($fallback in (Get-CursorStaticDownloadFallbacks)) {
        if (-not $fallback -or -not $fallback.DownloadUrl) {
            continue
        }
        $fallbackVersion = if (-not [string]::IsNullOrWhiteSpace($fallback.Version)) { $fallback.Version } else { "unknown" }
        Write-Warning ("Using bundled Cursor download fallback (version: {0})." -f $fallbackVersion)
        Write-CursorLog ("Falling back to bundled Cursor download URL: {0}" -f $fallback.DownloadUrl)
        Save-CursorInstallerMetadata -Info $fallback
        return $fallback
    }

    return $null
}

function Get-CursorInstallerDownloadInfoFromCursorSite {
    $downloadPage = "https://cursor.com/download"
    $headers = @{ "User-Agent" = "ai-dev-platform-bootstrap" }
    try {
        $response = Invoke-WebRequest -Uri $downloadPage -UseBasicParsing -Headers $headers -ErrorAction Stop
    } catch {
        Write-Warning ("Unable to retrieve Cursor download page ({0})." -f $_.Exception.Message)
        Write-CursorLog ("Cursor download page request failed: {0}" -f $_.Exception.Message)
        return $null
    }

    $content = $response.Content
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-Warning "Cursor download page response was empty."
        Write-CursorLog "Cursor download page response empty."
        return $null
    }

    $candidates = Get-CursorDownloadCandidatesFromHtml -Content $content
    $windowsCandidates = @($candidates | Where-Object { $_.Url -match 'win32' })
    if ($windowsCandidates.Count -eq 0) {
        Write-Warning "Cursor download page did not contain a recognizable Windows installer link."
        Write-CursorLog "Cursor download page parsing failed to locate Windows installer link."
        return $null
    }

    $preferred = $windowsCandidates | Where-Object { $_.Architecture -eq 'x64' -and $_.Variant -eq 'user' } | Select-Object -First 1
    if (-not $preferred) {
        $preferred = $windowsCandidates | Where-Object { $_.Architecture -eq 'x64' } | Select-Object -First 1
    }
    if (-not $preferred) {
        $preferred = $windowsCandidates[0]
    }

    $versionDisplay = if (-not [string]::IsNullOrWhiteSpace($preferred.Version)) { $preferred.Version } else { "unknown" }
    Write-CursorLog ("Cursor installer resolved from cursor.com (version: {0}, url: {1})" -f $versionDisplay, $preferred.Url)
    return [pscustomobject]@{
        DownloadUrl = $preferred.Url
        FileName    = $preferred.FileName
        Version     = $preferred.Version
    }
}

function Get-CursorDownloadCandidatesFromHtml {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    $pattern = 'https://downloads\.cursor\.com/[^\s"\\'']+'
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -eq 0) {
        return @()
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($match in $matches) {
        $url = $match.Value
        if (-not ($url -match '\.exe$')) {
            continue
        }
        if (-not $seen.Add($url)) {
            continue
        }

        $segments = $url.Split('/')
        if ($segments.Length -lt 3) {
            continue
        }
        $arch = $segments | Select-Object -Last 3 | Select-Object -First 1
        $setupType = $segments | Select-Object -Last 2 | Select-Object -First 1
        $fileName = Split-Path -Path $url -Leaf
        $variant = "unknown"
        if ($setupType -match 'user-setup') {
            $variant = "user"
        } elseif ($setupType -match 'system-setup') {
            $variant = "system"
        }
        $architecture = if ($arch -match 'arm') { "arm64" } elseif ($arch -match 'x64') { "x64" } else { "unknown" }

        $version = $null
        $versionMatch = [regex]::Match($fileName, '([0-9]+(?:\.[0-9]+)+)')
        if ($versionMatch.Success) {
            $version = $versionMatch.Groups[1].Value
        }

        $candidates.Add([pscustomobject]@{
            Url          = $url
            Variant      = $variant
            Architecture = $architecture
            FileName     = $fileName
            Version      = $version
        })
    }
    return @($candidates.ToArray())
}

function Get-CursorStaticDownloadFallbacks {
    $fallbacks = @(
        [pscustomobject]@{
            DownloadUrl = "https://downloads.cursor.com/production/823f58d4f60b795a6aefb9955933f3a2f0331d7b/win32/x64/user-setup/CursorUserSetup-x64-1.5.5.exe"
            FileName    = "CursorUserSetup-x64-1.5.5.exe"
            Version     = "1.5.5"
            Architecture = "x64"
            Variant      = "user"
        },
        [pscustomobject]@{
            DownloadUrl = "https://downloads.cursor.com/production/823f58d4f60b795a6aefb9955933f3a2f0331d7b/win32/arm64/user-setup/CursorUserSetup-arm64-1.5.5.exe"
            FileName    = "CursorUserSetup-arm64-1.5.5.exe"
            Version     = "1.5.5"
            Architecture = "arm64"
            Variant      = "user"
        },
        [pscustomobject]@{
            DownloadUrl = "https://downloads.cursor.com/production/823f58d4f60b795a6aefb9955933f3a2f0331d7b/win32/x64/system-setup/CursorSetup-x64-1.5.5.exe"
            FileName    = "CursorSetup-x64-1.5.5.exe"
            Version     = "1.5.5"
            Architecture = "x64"
            Variant      = "system"
        }
    )
    return $fallbacks
}

function Test-WslSudo {
    $check = Invoke-Wsl -Command "if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then echo yes; else echo no; fi"
    if ($check.ExitCode -eq 0 -and $check.Output.Trim().ToLowerInvariant() -eq "yes") {
        return $true
    }
    return $false
}

function Ensure-WslInteropEnabled {
    $status = Invoke-Wsl -Command "if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then cat /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null; else echo missing; fi"
    if ($status.ExitCode -eq 0 -and $status.Output.Trim() -eq "1") {
        return
    }

    Write-Host "WSL interoperability appears disabled. Attempting to re-enable automatically..." -ForegroundColor Yellow

    $configScript = @"
set -e
python3 <<'PY'
import configparser, os
path = '/etc/wsl.conf'
changed = False
config = configparser.RawConfigParser()
config.optionxform = str
if os.path.exists(path):
    with open(path, 'r') as f:
        config.read_file(f)
if not config.has_section('interop'):
    config.add_section('interop')
    changed = True
if config.get('interop', 'enabled', fallback='').lower() != 'true':
    config.set('interop', 'enabled', 'true')
    changed = True
if config.get('interop', 'appendWindowsPath', fallback='').lower() != 'true':
    config.set('interop', 'appendWindowsPath', 'true')
    changed = True
if changed:
    with open(path, 'w') as f:
        config.write(f)
print('CHANGED' if changed else 'UNCHANGED')
PY
"@
    $configResult = Invoke-Wsl -Command $configScript -AsRoot
    $needsRestart = $false
    if ($configResult.ExitCode -eq 0 -and ($configResult.Output.Trim().Split("`n") -contains 'CHANGED')) {
        $needsRestart = $true
    }
    if ($needsRestart) {
        Write-Host "Restarting WSL distribution '$DistroName' to apply configuration changes..." -ForegroundColor Yellow
        wsl.exe --terminate $DistroName 2>$null | Out-Null
        Start-Sleep -Seconds 2
    }

    $enableScript = @"
set -e
modprobe binfmt_misc 2>/dev/null || true
if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi
if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
  echo ':WSLInterop:M::MZ::/init:' > /proc/sys/fs/binfmt_misc/register
fi
echo 1 > /proc/sys/fs/binfmt_misc/WSLInterop
if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
  cat /proc/sys/fs/binfmt_misc/WSLInterop
else
  echo failed
  exit 14
fi
"@
    $enableResult = Invoke-Wsl -Command $enableScript -AsRoot
    if ($enableResult.ExitCode -eq 0 -and $enableResult.Output.Trim().Split("`n")[-1] -eq "1") {
        Write-Host "WSL interoperability re-enabled." -ForegroundColor Green
        return
    }

    Write-Section "WSL interoperability is still disabled after automated remediation"
    Write-Host "Attempting elevated WSL interop remediation..." -ForegroundColor Yellow
    $elevatedCommand = "modprobe binfmt_misc 2>/dev/null || true; mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true; if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then echo ':WSLInterop:M::MZ::/init:' > /proc/sys/fs/binfmt_misc/register; fi; echo 1 > /proc/sys/fs/binfmt_misc/WSLInterop"
    $escapedElevatedCommand = $elevatedCommand.Replace('"','"')
    $null = & wsl.exe -d $DistroName --user root -- sh -lc "$escapedElevatedCommand"
    $elevatedExit = $LASTEXITCODE
    if ($elevatedExit -eq 0) {
        $finalCheck = Invoke-Wsl -Command "if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then cat /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null; else echo missing; fi"
        if ($finalCheck.ExitCode -eq 0 -and $finalCheck.Output.Trim() -eq "1") {
            Write-Host "WSL interoperability re-enabled via elevated command." -ForegroundColor Green
            return
        }
    }

    Write-Warning "Automatic remediation failed."
    $manualInstructionsTemplate = @'
Run this from an elevated PowerShell prompt:
  wsl.exe -d {0} --user root -- sh -lc "modprobe binfmt_misc 2>/dev/null || true; mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true; if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then echo ':WSLInterop:M::MZ::/init:' > /proc/sys/fs/binfmt_misc/register; fi; echo 1 > /proc/sys/fs/binfmt_misc/WSLInterop"
After enabling interoperability, rerun this script.
'@
    $manualInstructions = $manualInstructionsTemplate -f $DistroName
    Write-Warning $manualInstructions
    throw "WSL interoperability could not be re-enabled automatically."
}


function Invoke-RobustDownload {
    param(
        [string]$Uri,
        [string]$Destination,
        [hashtable]$Headers = $null,
        [string]$Proxy = $null,
        [int]$Attempts = 3
    )

    if ([string]::IsNullOrWhiteSpace($Uri) -or [string]::IsNullOrWhiteSpace($Destination)) {
        throw "Uri and Destination are required."
    }

    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        $current = [System.Net.ServicePointManager]::SecurityProtocol
        $desired = $current -bor $tls12
        try {
            $tls13 = [System.Net.SecurityProtocolType]::Tls13
            $desired = $desired -bor $tls13
        } catch {
            # TLS 1.3 not available on this runtime; ignore.
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $desired
    } catch {
        # Ignore TLS configuration errors on downlevel PowerShell
    }

    $useBits = $false
    $bitsCommand = Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue
    if ($bitsCommand) {
        $useBits = $true
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $invokeParams = @{
                Uri             = $Uri
                OutFile         = $Destination
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if ($Headers) { $invokeParams["Headers"] = $Headers }
            if ($Proxy) {
                $invokeParams["Proxy"] = $Proxy
                $invokeParams["ProxyUseDefaultCredentials"] = $true
            }
            Invoke-WebRequest @invokeParams
            return $true
        } catch {
            Write-Warning ("Download attempt {0}/{1} with Invoke-WebRequest failed ({2})." -f $attempt, $Attempts, $_.Exception.Message)
            Write-CursorLog ("Invoke-WebRequest download attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
            if (Test-Path $Destination) {
                try { Remove-Item $Destination -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        if ($useBits) {
            try {
                Start-BitsTransfer -Source $Uri -Destination $Destination -ErrorAction Stop -Description "Downloading Cursor installer"
                return $true
            } catch {
                Write-Warning ("Download attempt {0}/{1} with Start-BitsTransfer failed ({2})." -f $attempt, $Attempts, $_.Exception.Message)
                Write-CursorLog ("Start-BitsTransfer download attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
                if (Test-Path $Destination) {
                    try { Remove-Item $Destination -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds ([Math]::Min(15, 3 * $attempt))
        }
    }

    return $false
}

function Open-UrlInBrowser {
    param([string]$Url, [string]$Description)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return
    }
    $target = $Url
    if ($target -and ($target.IndexOf(' ') -ge 0)) {
        $target = [Uri]::EscapeUriString($target)
    }
    $message = if ($Description) { $Description } else { $Url }
    try {
        Write-Host ("Opening {0}..." -f $message) -ForegroundColor Yellow
        Start-Process -FilePath $target | Out-Null
        return
    } catch {
        Write-CursorLog ("Start-Process launch for {0} failed: {1}" -f $target, $_.Exception.Message)
    }
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "start", "", $target) -WindowStyle Hidden | Out-Null
    } catch {
        Write-Warning ("Unable to open {0} automatically ({1})." -f $message, $_.Exception.Message)
    }
}

function Invoke-CursorManualDownloadFallback {
    param(
        [string]$DownloadUrl,
        [string]$ExpectedPath
    )

    Write-Warning "Automated Cursor download failed. Launching the Cursor download page for manual installation."
    if ($DownloadUrl) {
        Write-Host "If prompted, select the Windows installer download." -ForegroundColor Yellow
    }
    Open-UrlInBrowser -Url "https://cursor.com/download" -Description "Cursor download page"
    if ($DownloadUrl) {
        Write-Host ("You can also download the installer directly from: {0}" -f $DownloadUrl) -ForegroundColor Yellow
    }
    Write-Host "Once the installer finishes, complete the setup wizard. The script will wait for Cursor.exe to appear." -ForegroundColor Yellow

    $waitSeconds = 0
    $promptInterval = 30
    $timeoutSeconds = 300
    while ($waitSeconds -lt $timeoutSeconds) {
        Start-Sleep -Seconds 10
        $waitSeconds += 10
        $installPath = Get-CursorInstallPath
        if ($installPath) {
            Write-Host ("Detected Cursor installation at {0}. Continuing bootstrap." -f $installPath) -ForegroundColor Green
            Write-CursorLog ("Manual Cursor installation detected at {0} after {1} seconds." -f $installPath, $waitSeconds)
            return $true
        }
        if (($waitSeconds % $promptInterval) -eq 0) {
            try {
                $manualInstaller = Read-Host "Enter path to a downloaded Cursor installer to run now (press Enter to continue waiting)"
            } catch {
                $manualInstaller = $null
            }
            if (-not [string]::IsNullOrWhiteSpace($manualInstaller)) {
                $expandedPath = [Environment]::ExpandEnvironmentVariables($manualInstaller.Trim())
                if (-not (Test-Path $expandedPath)) {
                    Write-Warning ("The path '{0}' was not found. Continuing to wait for Cursor installation..." -f $expandedPath)
                    continue
                }
                Write-Host ("Attempting installation from '{0}'." -f $expandedPath)
                if (Install-CursorFromPath -Path $expandedPath -ExpectedVersion $null -ExpectedInstallPath $ExpectedPath) {
                    return $true
                }
                Write-Warning "Manual installer execution did not complete successfully. Continuing to wait for Cursor.exe to appear."
            }
        }
    }

    Write-Warning "Cursor executable was not detected after waiting five minutes. Complete the installation manually and rerun this script."
    Write-CursorLog "Cursor manual installation not detected within timeout window."
    return $false
}

function Install-CursorViaDownload {
    param([string]$ExpectedPath)

    Initialize-CursorInstallerContext
    Write-Host "Attempting Cursor installation via direct download fallback..." -ForegroundColor Yellow
    $downloadInfo = Get-CursorInstallerDownloadInfo
    if (-not $downloadInfo) {
        Write-Warning "Unable to resolve a Cursor installer download URL automatically. Install Cursor manually from https://cursor.com/download and rerun this script."
        Write-CursorLog "Cursor installer download info unavailable; aborting automated download."
        return $false
    }

    $downloadUrl = $downloadInfo.DownloadUrl
    $fileName = $downloadInfo.FileName
    $expectedVersion = $downloadInfo.Version
    $cachePath = Get-CursorInstallerCachePath -Version $expectedVersion
    $installerPath = $null

    if ($cachePath -and (Test-Path $cachePath)) {
        Write-CursorLog ("Found cached Cursor installer at {0}" -f $cachePath)
        if (Test-CursorInstallerSignature -Path $cachePath) {
            $installerPath = $cachePath
        } else {
            Write-CursorLog ("Removing cached installer due to failed signature validation: {0}" -f $cachePath)
            try {
                Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
            } catch {
                Write-CursorLog ("Failed to delete invalid cached installer {0}: {1}" -f $cachePath, $_.Exception.Message)
            }
        }
    }

    $tempPath = $null
    if (-not $installerPath) {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) $fileName
        $token = $null
        foreach ($candidate in @($env:GH_TOKEN, $env:GITHUB_TOKEN)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $token = $candidate
                break
            }
        }
        $proxy = $null
        foreach ($candidateProxy in @($env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY)) {
            if (-not [string]::IsNullOrWhiteSpace($candidateProxy)) {
                $proxy = $candidateProxy
                break
            }
        }
        Write-Host "Downloading Cursor installer from $downloadUrl"
        Write-CursorLog ("Downloading Cursor installer from {0}" -f $downloadUrl)
        try {
            $headers = @{ "User-Agent" = "ai-dev-platform-bootstrap" }
            if ($token) {
                $headers["Authorization"] = "Bearer $token"
            }
            if (-not (Invoke-RobustDownload -Uri $downloadUrl -Destination $tempPath -Headers $headers -Proxy $proxy)) {
                throw "All automated download attempts failed."
            }
        } catch {
            Write-Warning "Failed to download Cursor installer automatically ($($_.Exception.Message)). Install Cursor manually from https://cursor.com/download and rerun this script."
            Write-CursorLog ("Cursor installer download failed: {0}" -f $_.Exception.Message)
            if ($tempPath) {
                try { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue } catch { }
            }
            return Invoke-CursorManualDownloadFallback -DownloadUrl $downloadUrl -ExpectedPath $ExpectedPath
        }

        try {
            $hash = Get-FileHash -Path $tempPath -Algorithm SHA256
            Write-CursorLog ("Downloaded Cursor installer SHA256 hash: {0}" -f $hash.Hash)
        } catch {
            Write-CursorLog ("Failed to compute hash for downloaded Cursor installer {0}: {1}" -f $tempPath, $_.Exception.Message)
        }

        if (-not (Test-CursorInstallerSignature -Path $tempPath)) {
            try { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue } catch { }
            return Invoke-CursorManualDownloadFallback -DownloadUrl $downloadUrl -ExpectedPath $ExpectedPath
        }

        if ($cachePath) {
            try {
                Copy-Item -Path $tempPath -Destination $cachePath -Force
                Write-CursorLog ("Cached Cursor installer at {0}" -f $cachePath)
                $installerPath = $cachePath
            } catch {
                Write-CursorLog ("Failed to cache Cursor installer at {0}: {1}" -f $cachePath, $_.Exception.Message)
                $installerPath = $tempPath
            }
        } else {
            $installerPath = $tempPath
        }
    }

    $result = $false
    if ($installerPath) {
        $result = Invoke-CursorInstaller -InstallerPath $installerPath -ExpectedVersion $expectedVersion -ExpectedPath $ExpectedPath
    }

    if ($tempPath -and (Test-Path $tempPath) -and ($installerPath -ne $tempPath)) {
        try { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $result) {
        return Invoke-CursorManualDownloadFallback -DownloadUrl $downloadUrl -ExpectedPath $ExpectedPath
    }

    return $result
}

function Ensure-Cursor {
    Write-Section "Ensuring Cursor editor is installed"
    Initialize-CursorInstallerContext
    Ensure-CursorLogAdvertised
    Write-CursorLog "Starting Cursor installation verification."
    $cursorPath = Join-Path $env:LOCALAPPDATA "Programs\Cursor\Cursor.exe"
    $existingPath = Get-CursorInstallPath
    if ($existingPath) {
        Write-Host "Cursor already installed at $existingPath."
        Write-CursorLog ("Cursor already installed at {0}" -f $existingPath)
        return
    }
    if ($CursorInstallerPath) {
        Write-Host "Using provided Cursor installer path '$CursorInstallerPath'."
        if (Install-CursorFromPath -Path $CursorInstallerPath -ExpectedVersion $null -ExpectedInstallPath $cursorPath) {
            return
        }
        Write-Warning "Custom Cursor installer failed. Falling back to automated options."
    }
    try {
        Ensure-Winget
    } catch {
        Write-Warning "Unable to verify winget availability ($_). Attempting direct-download fallback."
        Write-CursorLog ("Winget unavailable: {0}" -f $_.Exception.Message)
        $fallbackInstalled = Install-CursorViaDownload -ExpectedPath $cursorPath
        if (-not $fallbackInstalled) {
            Write-Warning "Install Cursor manually from https://cursor.com/download and rerun this script."
        }
        return
    }

    $cursorId = "Cursor.Cursor"
    $installed = $false
    try {
        $listOutput = winget list --id $cursorId --exact --accept-source-agreements 2>$null
        if ($LASTEXITCODE -eq 0 -and $listOutput -match [regex]::Escape($cursorId)) {
            $installed = $true
        }
    } catch {
        Write-Warning "winget list failed to detect Cursor ($_). Continuing with installation attempt."
    }

    if ($installed) {
        $detectedPath = Get-CursorInstallPath
        if ($detectedPath) {
            Write-Host "Cursor already installed at $detectedPath."
            Write-CursorLog ("Cursor already installed per winget listing at {0}" -f $detectedPath)
            return
        }
    }

    Write-Host "Installing Cursor editor via winget..."
    $arguments = @(
        "install", "-e", "--id", $cursorId,
        "--accept-package-agreements", "--accept-source-agreements"
    )
    $proc = Start-Process -FilePath "winget" -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    switch ($proc.ExitCode) {
        0 {
            if (Confirm-CursorInstallation -ExpectedVersion $null -ExpectedPath $cursorPath) {
                $postInstallPath = Get-CursorInstallPath
                if ($postInstallPath) {
                    Write-Host "Cursor installation completed successfully at $postInstallPath."
                    Write-CursorLog ("Cursor installed via winget at {0}" -f $postInstallPath)
                    return
                }
            } else {
                Write-Warning "Cursor installer reported success but $cursorPath was not found. Attempting direct-download fallback."
            }
        }
        3010 {
            Write-Warning "Cursor installation signaled a reboot requirement. Restart Windows to finish installation, then rerun this script if needed."
            return
        }
        default {
            Write-Warning "Cursor installer exited with code $($proc.ExitCode). Attempting direct-download fallback."
        }
    }

    $fallbackInstalled = Install-CursorViaDownload -ExpectedPath $cursorPath
    if (-not $fallbackInstalled) {
        Write-Warning "Cursor installation could not be automated. Install Cursor manually from https://cursor.com/download and rerun this script."
    }
}

function Ensure-CursorExtensions {
    Write-Section "Ensuring Cursor AI extensions are installed"
    $cursorPath = Get-CursorInstallPath
    if (-not $cursorPath) {
        Write-Warning "Cursor executable not located; skipping extension installation."
        Write-CursorLog "Cursor path unavailable; extension installation skipped."
        return
    }

    $cliPath = Get-CursorCliPath -CursorExePath $cursorPath
    if (-not $cliPath -or -not (Test-Path $cliPath)) {
        Write-Warning "Cursor command-line interface not found. Install extensions manually via the Cursor marketplace."
        Write-CursorLog "Cursor CLI not found; extension installation skipped."
        return
    }

    $targets = @(
        [pscustomobject]@{ Id = "openai.chatgpt"; Label = "OpenAI Codex" },
        [pscustomobject]@{ Id = "anthropic.claude-code"; Label = "Claude Code" }
    )

    $installedExtensions = @()
    try {
        $rawList = & "$cliPath" --list-extensions 2>$null
        if ($rawList) {
            $installedExtensions = $rawList -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    } catch {
        Write-CursorLog ("Failed to list existing Cursor extensions: {0}" -f $_.Exception.Message)
        $installedExtensions = @()
    }

    foreach ($target in $targets) {
        $extensionId = $target.Id
        $label = $target.Label
        $alreadyInstalled = $false
        foreach ($entry in $installedExtensions) {
            if ($entry.Trim().ToLowerInvariant() -eq $extensionId) {
                $alreadyInstalled = $true
                break
            }
        }
        if ($alreadyInstalled) {
            Write-CursorLog ("Cursor extension {0} is already installed." -f $extensionId)
            continue
        }

        Write-Host ("Installing Cursor extension {0} ({1})..." -f $label, $extensionId)
        Write-CursorLog ("Installing Cursor extension {0}." -f $extensionId)
        try {
            & "$cliPath" --install-extension $extensionId --force *> $null
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Start-Sleep -Seconds 1
                try {
                    $verifyList = & "$cliPath" --list-extensions 2>$null
                    if ($verifyList) {
                        $installedExtensions = $verifyList -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    }
                } catch { }
                if ($installedExtensions -and ($installedExtensions | ForEach-Object { $_.Trim().ToLowerInvariant() }) -contains $extensionId) {
                    Write-Host ("Cursor extension {0} installed successfully." -f $label)
                    Write-CursorLog ("Cursor extension {0} installed successfully." -f $extensionId)
                } else {
                    Write-Warning ("Cursor extension {0} installation reported success but was not detected. Install it manually if it remains missing." -f $label)
                    Write-CursorLog ("Cursor extension {0} installation reported success but verification failed." -f $extensionId)
                }
            } else {
                Write-Warning ("Failed to install Cursor extension {0} (exit {1}). Install it manually via the Cursor marketplace." -f $label, $exitCode)
                Write-CursorLog ("Cursor extension {0} installation failed with exit code {1}." -f $extensionId, $exitCode)
            }
        } catch {
            Write-Warning ("Failed to install Cursor extension {0} ({1}). Install it manually via the Cursor marketplace." -f $label, $_.Exception.Message)
            Write-CursorLog ("Cursor extension {0} installation error: {1}" -f $extensionId, $_.Exception.Message)
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

function Test-GcpBillingEnabled {
    param([string]$ProjectId)

    $command = "gcloud beta billing projects describe $ProjectId --format='value(billingEnabled)'"
    $result = Invoke-Wsl -Command $command
    $enabled = $false
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Output)) {
        $value = $result.Output.Trim().ToLower()
        if ($value -eq 'true') {
            $enabled = $true
        }
    }
    return [PSCustomObject]@{
        Enabled  = $enabled
        ExitCode = $result.ExitCode
        Output   = $result.Output
    }
}

function Ensure-GcpBillingEnabled {
    param([string]$ProjectId)

    $initialStatus = Test-GcpBillingEnabled -ProjectId $ProjectId
    if ($initialStatus.Enabled) {
        return $true
    }

    Write-Warning "Billing is not enabled for project '$ProjectId'."
    if ($initialStatus.ExitCode -ne 0) {
        Write-Warning "Unable to determine billing status automatically (exit $($initialStatus.ExitCode)). Enable billing in Google Cloud Console and rerun."
        Open-UrlInBrowser -Url ("https://console.cloud.google.com/billing/projects?project={0}" -f $ProjectId) -Description "Google Cloud billing project page"
        return $false
    }

    $accountsResult = Invoke-Wsl -Command "gcloud beta billing accounts list --format=json"
    if ($accountsResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($accountsResult.Output)) {
        Write-Warning "Unable to list accessible billing accounts automatically. Enable billing via Google Cloud Console and rerun."
        Open-UrlInBrowser -Url "https://console.cloud.google.com/billing" -Description "Google Cloud billing console"
        return $false
    }

    try {
        $accounts = $accountsResult.Output | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse billing accounts information. Enable billing manually and rerun."
        return $false
    }

    if (-not $accounts) {
        Write-Warning "No billing accounts were returned by gcloud. Ensure you have access to an active billing account and rerun."
        Open-UrlInBrowser -Url "https://console.cloud.google.com/billing/create" -Description "Google Cloud billing account creation page"
        return $false
    }

    $openAccounts = @($accounts | Where-Object { $_.open -eq $true })
    if ($openAccounts.Count -eq 0) {
        Write-Warning "No open billing accounts are available. Enable or create a billing account in Google Cloud Console and rerun."
        Open-UrlInBrowser -Url "https://console.cloud.google.com/billing" -Description "Google Cloud billing console"
        return $false
    }

    Write-Host "Available billing accounts:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $openAccounts.Count; $i++) {
        $acct = $openAccounts[$i]
        $id = $null
        if ($acct.billingAccountId) {
            $id = $acct.billingAccountId
        } elseif ($acct.name) {
            $id = ($acct.name -replace '^billingAccounts/', '')
        }
        if (-not $id) {
            $id = "(unknown id)"
        }
        $displayName = if ($acct.displayName) { $acct.displayName } else { "(no display name)" }
        Write-Host ("[{0}] {1} - {2}" -f $i, $id, $displayName)
    }

    $selectedAccountId = $null
    if ($openAccounts.Count -eq 1) {
        $single = $openAccounts[0]
        $singleId = if ($single.billingAccountId) { $single.billingAccountId } elseif ($single.name) { ($single.name -replace '^billingAccounts/', '') } else { $null }
        if ($singleId) {
            $confirm = Read-Host "Link project '$ProjectId' to billing account '$singleId'? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm -match '^[Yy]') {
                $selectedAccountId = $singleId
            } else {
                Write-Warning "Skipping automatic billing linkage at user request."
                Open-UrlInBrowser -Url ("https://console.cloud.google.com/billing/projects?project={0}" -f $ProjectId) -Description "Google Cloud billing project page"
                return $false
            }
        }
    }

    if (-not $selectedAccountId) {
        for ($attempt = 1; $attempt -le 3 -and -not $selectedAccountId; $attempt++) {
            $prompt = "Enter the number of the billing account to link to '$ProjectId'"
            if ($attempt -lt 3) {
                $prompt += " (press Enter to skip)"
            }
            $selection = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($selection)) {
                Write-Warning "Skipping automatic billing linkage. Enable billing in Google Cloud Console and rerun."
                return $false
            }

            $selection = $selection.Trim()
            $parsedIndex = 0
            if ([int]::TryParse($selection, [ref]$parsedIndex)) {
                if ($parsedIndex -lt 0 -or $parsedIndex -ge $openAccounts.Count) {
                    Write-Warning "Selection '$selection' is out of range. Try again."
                    continue
                }
                $acct = $openAccounts[$parsedIndex]
                if ($acct.billingAccountId) {
                    $selectedAccountId = $acct.billingAccountId
                } elseif ($acct.name) {
                    $selectedAccountId = ($acct.name -replace '^billingAccounts/', '')
                }
                if (-not $selectedAccountId) {
                    Write-Warning "Unable to determine billing account ID for selection '$selection'."
                }
            } else {
                $selectedAccountId = ($selection -replace '^billingAccounts/', '')
            }
        }
    }

    if (-not $selectedAccountId) {
        Write-Warning "Unable to resolve a billing account selection. Enable billing manually and rerun."
        Open-UrlInBrowser -Url ("https://console.cloud.google.com/billing/projects?project={0}" -f $ProjectId) -Description "Google Cloud billing project page"
        return $false
    }

    $linkCommand = "gcloud beta billing projects link $ProjectId --billing-account $selectedAccountId"
    $linkResult = Invoke-Wsl -Command $linkCommand
    if ($linkResult.ExitCode -ne 0) {
        Write-Warning "Failed to link billing account '$selectedAccountId' to project '$ProjectId' (exit $($linkResult.ExitCode)). Resolve billing manually and rerun."
        Open-UrlInBrowser -Url ("https://console.cloud.google.com/billing/projects?project={0}" -f $ProjectId) -Description "Google Cloud billing project page"
        return $false
    }

    $finalStatus = Test-GcpBillingEnabled -ProjectId $ProjectId
    if ($finalStatus.Enabled) {
        Write-Host "Linked billing account '$selectedAccountId' to project '$ProjectId'." -ForegroundColor Green
        return $true
    }

    Write-Warning "Billing still appears disabled after linking account '$selectedAccountId'. Verify in Google Cloud Console and rerun."
    Open-UrlInBrowser -Url ("https://console.cloud.google.com/billing/projects?project={0}" -f $ProjectId) -Description "Google Cloud billing project page"
    return $false
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
            'cursor.com',
            'downloads.cursor.com',
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
DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates curl build-essential python3 python3-pip unzip pkg-config wslu
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
if [ -z "$url" ]; then
  exit 0
fi

escape_pwsh() {
  printf "%s" "$1" | sed "s/'/''/g"
}

# Try wslview if available (WSL-friendly browser launcher)
if command -v wslview >/dev/null 2>&1; then
  if wslview "$url" >/dev/null 2>&1; then
    exit 0
  fi
fi

escaped="$(escape_pwsh "$url")"
powershell.exe -NoProfile -Command "Start-Process '$escaped'" >/dev/null 2>&1 && exit 0
/mnt/c/Windows/System32/cmd.exe /c start "" "$url" >/dev/null 2>&1 && exit 0
printf 'Open this URL manually: %s\n' "$url" >&2
exit 0
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
        Ensure-WslInteropEnabled
        Write-Host "Launching browser for gcloud login." -ForegroundColor Yellow
        $loginResult = Invoke-Wsl -Command "BROWSER=/tmp/open-in-windows.sh gcloud auth login --launch-browser"
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
        if (-not (Ensure-GcpBillingEnabled -ProjectId $projectId)) {
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        Ensure-WslInteropEnabled
        $adcResult = Invoke-Wsl -Command "BROWSER=/tmp/open-in-windows.sh gcloud auth application-default login --launch-browser"
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
            'cd $HOME/ai-dev-platform',
            "./scripts/bootstrap-infra.sh"
        )
        $bootstrapResult = Invoke-Wsl -Command ($bootstrapCommands -join '; ')
        if ($bootstrapResult.ExitCode -ne 0) {
            Write-Warning "Infrastructure bootstrap exited with $($bootstrapResult.ExitCode). Review output above and rerun after addressing the issue."
            return [PSCustomObject]@{ Completed = $false; GeneratedInfisical = $generatedInfisical }
        }

        Write-Section "GitHub environment configuration"
        $configureCommands = @(
            'cd $HOME/ai-dev-platform',
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
        Write-Warning "Cursor executable not detected. Install it from https://cursor.com/download, then sign into Codex and Claude Code."
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
Ensure-CursorExtensions

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
