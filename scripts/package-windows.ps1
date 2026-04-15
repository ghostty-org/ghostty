[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$OutputRoot = "dist/artifacts",

    [switch]$SkipBuild,

    [switch]$RequireInstaller
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$outputRootPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
$userHome = if ($env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOMEDRIVE -and $env:HOMEPATH) {
    "$($env:HOMEDRIVE)$($env:HOMEPATH)"
} else {
    Join-Path "C:" "Users"
}
$localAppData = if ($env:LOCALAPPDATA) {
    $env:LOCALAPPDATA
} else {
    Join-Path $userHome "AppData\Local"
}
$stageBase = Join-Path $outputRootPath "winghostty-$Version-windows-x64"
$portableRoot = Join-Path $stageBase "winghostty"
$zipPath = Join-Path $stageBase "winghostty-$Version-windows-x64-portable.zip"
$installerPath = Join-Path $stageBase "winghostty-$Version-windows-x64-setup.exe"
$checksumsPath = Join-Path $stageBase "SHA256SUMS.txt"
$zigOutBin = Join-Path $repoRoot "zig-out/bin"
$zigOutShare = Join-Path $repoRoot "zig-out/share/ghostty"
$exePath = Join-Path $zigOutBin "winghostty.exe"
$licensePath = Join-Path $repoRoot "LICENSE"
$readmePath = Join-Path $repoRoot "README.md"
$configTemplatePath = Join-Path $repoRoot "src/config/config-template"
$innoScriptPath = Join-Path $repoRoot "dist/windows/winghostty.iss"
$iconPath = Join-Path $repoRoot "dist/windows/winghostty.ico"

if (-not $env:ZIG_LOCAL_CACHE_DIR) {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $repoRoot ".zig-cache"
}
if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $localAppData "zig"
}

New-Item -ItemType Directory -Path $env:ZIG_LOCAL_CACHE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $env:ZIG_GLOBAL_CACHE_DIR -Force | Out-Null

function Remove-TreeIfPresent {
    param([string]$PathToRemove)

    if (-not (Test-Path -LiteralPath $PathToRemove)) {
        return
    }

    $resolved = [System.IO.Path]::GetFullPath($PathToRemove)
    if (-not $resolved.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside repo root: $resolved"
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Copy-Tree {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

if (-not $SkipBuild) {
    Push-Location $repoRoot
    try {
        & zig build -Demit-exe=true "-Dversion-string=$Version"
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Expected build output was not found: $exePath"
}

Remove-TreeIfPresent -PathToRemove $stageBase
New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null

Get-ChildItem -LiteralPath $zigOutBin -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $portableRoot -Force
}

Copy-Item -LiteralPath $licensePath -Destination (Join-Path $portableRoot "LICENSE") -Force
Copy-Item -LiteralPath $configTemplatePath -Destination (Join-Path $portableRoot "config-template.ghostty") -Force
Copy-Item -LiteralPath $readmePath -Destination (Join-Path $portableRoot "README.md") -Force
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $portableRoot "winghostty.ico") -Force

if (Test-Path -LiteralPath $zigOutShare) {
    Copy-Tree -Source $zigOutShare -Destination (Join-Path $portableRoot "share")
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $portableRoot -DestinationPath $zipPath -Force

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $candidates = @(
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $iscc = @{ Source = $candidate }
            break
        }
    }
}

if ($iscc) {
    & $iscc.Source `
        "/DMyAppVersion=$Version" `
        "/DStageDir=$portableRoot" `
        "/DOutputDir=$stageBase" `
        "/DSourceDir=$repoRoot" `
        $innoScriptPath
}
elseif ($RequireInstaller) {
    throw "Inno Setup compiler (ISCC.exe) was not found."
}
else {
    Write-Warning "ISCC.exe not found. Skipping installer build."
}

$hashTargets = @(
    @{
        Name = [System.IO.Path]::GetFileName($zipPath)
        Path = $zipPath
    }
)

if (Test-Path -LiteralPath $installerPath) {
    $hashTargets += @{
        Name = [System.IO.Path]::GetFileName($installerPath)
        Path = $installerPath
    }
}

$hashLines = foreach ($target in $hashTargets) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target.Path).Hash.ToLowerInvariant()
    "$hash *$($target.Name)"
}

Set-Content -LiteralPath $checksumsPath -Value $hashLines

Write-Host "Portable ZIP: $zipPath"
if (Test-Path -LiteralPath $installerPath) {
    Write-Host "Installer    : $installerPath"
}
Write-Host "Checksums    : $checksumsPath"
