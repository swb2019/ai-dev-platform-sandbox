Param(
    [string]$Workspace
)

if (-not $Workspace -or $Workspace -eq '') {
    if ($env:LOCAL_WORKSPACE_FOLDER) {
        $Workspace = $env:LOCAL_WORKSPACE_FOLDER
    } else {
        $Workspace = (Get-Location).Path
    }
}
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$destDir = Join-Path $Workspace 'tmp/cursor-tools'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
} catch {
    # ZipFile assembly is already available or cannot be loaded; continue without failing.
}

function Test-VsixFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $archive.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Get-VsixPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Publisher,
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $vsixPath = Join-Path $destDir $FileName
    if (Test-Path $vsixPath) {
        if (Test-VsixFile -Path $vsixPath) {
            Write-Host "$Extension VSIX already present at $vsixPath."
            return $vsixPath
        }

        Write-Warning "$Extension VSIX at $vsixPath failed validation; redownloading."
        Remove-Item $vsixPath -Force
    }

    $uri = "https://$Publisher.gallery.vsassets.io/_apis/public/gallery/publisher/$Publisher/extension/$Extension/latest/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
    try {
        Write-Host "Downloading $Extension VSIX from $uri..."
        Invoke-WebRequest -Uri $uri -OutFile $vsixPath -UseBasicParsing -ErrorAction Stop
        if (Test-VsixFile -Path $vsixPath) {
            return $vsixPath
        }

        Write-Warning "Downloaded $Extension VSIX failed validation; removing corrupted file."
        Remove-Item $vsixPath -Force
    } catch {
        Write-Warning "Failed to download $Extension VSIX: $($_.Exception.Message)"
        if (Test-Path $vsixPath) {
            Remove-Item $vsixPath -Force
        }
        return $null
    }

    return $null
}

function Ensure-CodexBinary {
    param(
        [Parameter(Mandatory = $true)][string]$VsixPath
    )

    $codexTarget = Join-Path $destDir 'codex'
    if (Test-Path $codexTarget) {
        Write-Host "Codex binary already present at $codexTarget."
        return
    }

    if (-not (Test-VsixFile -Path $VsixPath)) {
        Write-Warning "Codex VSIX not available; skipping binary extraction."
        return
    }

    $extractDir = Join-Path $destDir 'codex-extract'
    if (Test-Path $extractDir) {
        Remove-Item $extractDir -Recurse -Force
    }

    try {
        Expand-Archive -Path $VsixPath -DestinationPath $extractDir -Force
        $source = Join-Path $extractDir 'extension/bin/linux-x86_64/codex'
        if (Test-Path $source) {
            Copy-Item $source $codexTarget -Force
            Write-Host "Extracted Codex binary to $codexTarget."
        } else {
            Write-Warning "Codex binary not found inside $VsixPath."
        }
    } catch {
        Write-Warning "Failed to extract Codex binary: $($_.Exception.Message)"
    } finally {
        if (Test-Path $extractDir) {
            Remove-Item $extractDir -Recurse -Force
        }
    }
}

$codexVsix = Get-VsixPackage -Publisher 'openai' -Extension 'chatgpt' -FileName 'openai-chatgpt.vsix'
Ensure-CodexBinary -VsixPath $codexVsix

$claudeVsix = Get-VsixPackage -Publisher 'anthropic' -Extension 'claude-code' -FileName 'anthropic-claude-code.vsix'
if ($null -ne $claudeVsix) {
    Write-Host "Claude Code VSIX cached at $claudeVsix."
} else {
    Write-Warning "Claude Code VSIX could not be downloaded."
}

if ($null -ne $codexVsix) {
    Write-Host "OpenAI Codex VSIX cached at $codexVsix."
} else {
    Write-Warning "OpenAI Codex VSIX could not be downloaded."
}
