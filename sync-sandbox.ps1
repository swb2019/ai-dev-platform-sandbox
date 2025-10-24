Param(
    [string]$RepoDir = "C:\dev\ai-dev-platform"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $RepoDir)) {
    throw "Repository directory '$RepoDir' not found."
}

$originUrl = git remote get-url origin 2>$null
if ($originUrl -match 'github.com[:/](.+?)(\.git)?$') {
    $SandboxRepo = $matches[1]
    $OriginUrl = "https://github.com/$SandboxRepo.git"
} else {
    throw "Sandbox repository remote could not be determined. Configure 'origin' before running the script."
}

function Ensure-GitHubAuthentication {
    $statusOutput = try {
        & gh auth status --hostname github.com 2>&1
    } catch {
        $_.Exception.Message
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub CLI is not authenticated. Launching browser login..." -ForegroundColor Yellow
        gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org"
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub authentication failed."
        }
    }
}

function Ensure-RepositoryExists {
    gh repo view $SandboxRepo --json name *> $null
    if ($LASTEXITCODE -eq 0) {
        return
    }
    Write-Host "GitHub repository '$SandboxRepo' not found. Creating it now..." -ForegroundColor Yellow
    gh repo create $SandboxRepo --private --source $RepoDir --push --confirm --disable-wiki --disable-issues
    if ($LASTEXITCODE -ne 0) {
        throw "Automatic repository creation failed. Create the repo manually and rerun."
    }
    Write-Host "Repository '$SandboxRepo' created." -ForegroundColor Green
}

Push-Location $RepoDir
try {
    Ensure-GitHubAuthentication
    Ensure-RepositoryExists

    $upstreamUrl = "https://github.com/swb2019/ai-dev-platform.git"
    if (-not ((git remote | Select-String -Quiet "^upstream$"))) {
        git remote add upstream $upstreamUrl
    } else {
        git remote set-url upstream $upstreamUrl
    }

    git fetch upstream

    $gitStatus = git status --porcelain
    if ($gitStatus) {
        throw "Working tree is not clean. Commit or stash changes before synchronization."
    }

    git checkout main
    git reset --hard upstream/main

    if (-not ((git remote | Select-String -Quiet "^origin$"))) {
        git remote add origin $OriginUrl
    } else {
        git remote set-url origin $OriginUrl
    }

    git push --force-with-lease origin main

    Write-Host "Sandbox repository synchronized with upstream." -ForegroundColor Green
}
finally {
    Pop-Location
}
