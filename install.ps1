# git-ai-cb Windows PowerShell one-click installer.
#
# Locates Git Bash's bash.exe automatically, downloads install.sh and runs it.
#
# Usage (in PowerShell):
#   irm https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main/install.ps1 | iex
#
# Other platforms:
#   curl -fsSL https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main/install.sh | bash
#
$ErrorActionPreference = "Stop"

$Remote = "https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main"

function Find-Bash {
    $inPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += "$env:ProgramFiles\Git\bin\bash.exe" }
    if ($env:ProgramFiles) { $candidates += "$env:ProgramFiles\Git\usr\bin\bash.exe" }
    if ($env:ProgramFiles_x86_Unused -eq $null) { $pf86 = ${env:ProgramFiles(x86)} } else { $pf86 = $null }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $candidates += "$pf86\Git\bin\bash.exe" }
    if ($env:LOCALAPPDATA) { $candidates += "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe" }
    if ($env:LOCALAPPDATA) { $candidates += "$env:LOCALAPPDATA\Programs\Git\usr\bin\bash.exe" }

    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
        $try1 = Join-Path $gitRoot "bin\bash.exe"
        if (Test-Path $try1) { return $try1 }
        $try2 = Join-Path $gitRoot "usr\bin\bash.exe"
        if (Test-Path $try2) { return $try2 }
    }

    $regPaths = @("HKLM:\SOFTWARE\GitForWindows", "HKCU:\SOFTWARE\GitForWindows")
    foreach ($rp in $regPaths) {
        $prop = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        if ($prop -and $prop.InstallPath) {
            $try3 = Join-Path $prop.InstallPath "bin\bash.exe"
            if (Test-Path $try3) { return $try3 }
        }
    }

    return $null
}

$bash = Find-Bash
if (-not $bash) {
    Write-Error "No Git Bash (bash.exe) found. Install Git for Windows first: https://git-scm.com/download/win"
    exit 1
}
Write-Host "Git Bash: $bash"

$tmp = Join-Path $env:TEMP "git-ai-cb-install.sh"

Write-Host "Downloading install.sh ..."
curl.exe -fsSL "$Remote/install.sh" -o $tmp
if ($LASTEXITCODE -ne 0) {
    Invoke-WebRequest -Uri "$Remote/install.sh" -OutFile $tmp -UseBasicParsing
}

Write-Host "Running installer ..."
& $bash $tmp
$code = $LASTEXITCODE
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($code -ne 0) {
    Write-Error "Installer failed with exit code $code"
    exit $code
}

Write-Host ""
Write-Host "Install done. Restart CodeBuddy to take effect."
Write-Host "Then use: git-ai-cb -v / status / update / uninstall"
