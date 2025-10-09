Param(
    [string]$RepoSlug = "swb2019/ai-dev-platform",
    [string]$Branch   = "main"
)

function Ensure-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$name' not found. Install it and re-run."
        exit 1
    }
}

Ensure-Command git
Ensure-Command ssh
Ensure-Command ssh-keygen

$sshDir   = Join-Path $env:USERPROFILE ".ssh"
$privKey  = Join-Path $sshDir "id_ed25519"
$pubKey   = "$privKey.pub"

if (-not (Test-Path $pubKey)) {
    Write-Host "`nNo SSH key detected at $pubKey."
    $email = Read-Host "Enter the email/comment you want in the SSH key"
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    ssh-keygen -t ed25519 -C $email -f $privKey
    Write-Host "`nKey generated."
} else {
    Write-Host "`nReusing existing SSH key at $pubKey."
}

$pub = Get-Content $pubKey
Write-Host "`nCopy the following SSH public key, then paste it into GitHub (Settings → SSH and GPG keys → New SSH key):`n"
Write-Host $pub
if ($PSVersionTable.PSEdition -eq "Desktop") {
    $copy = Read-Host "Press Enter after copying, or type 'copy' to copy now"
    if ($copy -eq "copy") {
        $pub | Set-Clipboard
        Write-Host "Key copied to clipboard."
    }
} else {
    $null = Read-Host "Press Enter after copying"
}

$githubKeyUrl = "https://github.com/settings/ssh/new"
Write-Host "`nOpening GitHub SSH key settings..."
Start-Process $githubKeyUrl
$null = Read-Host "Add the key in the browser, then press Enter to continue"

Write-Host "`nTesting SSH connection to GitHub..."
ssh -T git@github.com

$remoteUrl = (git remote get-url origin) 2>$null
if (-not $remoteUrl) {
    $remoteUrl = "git@github.com:$RepoSlug.git"
    git remote add origin $remoteUrl
    Write-Host "Added origin $remoteUrl"
} elseif ($remoteUrl -notlike "git@github.com*") {
    $sshUrl = "git@github.com:$RepoSlug.git"
    Write-Host "Switching origin to SSH ($sshUrl)"
    git remote set-url origin $sshUrl
}

Write-Host "`nPushing $Branch..."
git push -u origin $Branch
Write-Host "`nDone."
