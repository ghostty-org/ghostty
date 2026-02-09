# make_pri.ps1 — Generate resources.pri for Ghostty's unpackaged WinUI 3 integration.
#
# The WinUI XAML resource system requires a resources.pri file whose resource map
# name matches the application module. For unpackaged apps, this is the exe name.
#
# Usage: powershell -ExecutionPolicy Bypass -File make_pri.ps1 <output_dir>

param(
    [Parameter(Mandatory=$true)]
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

# Find makepri.exe
$makepri = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\makepri.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if (-not $makepri) {
    Write-Error "makepri.exe not found in Windows SDK"
    exit 1
}

Write-Host "Using makepri: $($makepri.FullName)"

# Find the WinAppSDK runtime framework package directory (contains the .pri files)
$runtimeDir = Get-ChildItem "C:\Program Files\WindowsApps\Microsoft.WindowsAppRuntime.1.*_x64__8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $runtimeDir) {
    Write-Warning "WinAppSDK runtime not found. Skipping PRI generation."
    exit 0
}

Write-Host "WinAppSDK runtime: $($runtimeDir.FullName)"

# Create a temp working directory
$tempDir = Join-Path $env:TEMP "ghostty_pri_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # Create the priconfig.xml for our app
    $configXml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources targetOsVersion="10.0.0" majorVersion="1">
  <packaging>
    <autoResourcePackage qualifier="Language"/>
    <autoResourcePackage qualifier="Scale"/>
  </packaging>
  <index root="$tempDir" startIndexAt="$tempDir">
    <default>
      <qualifier name="Language" value="en-US"/>
      <qualifier name="Contrast" value="standard"/>
      <qualifier name="Scale" value="100"/>
      <qualifier name="HomeRegion" value="001"/>
      <qualifier name="TargetSize" value="256"/>
      <qualifier name="LayoutDirection" value="LTR"/>
      <qualifier name="DXFeatureLevel" value="DX9"/>
      <qualifier name="Configuration" value=""/>
      <qualifier name="AlternateForm" value=""/>
      <qualifier name="Theme" value="dark"/>
    </default>
    <indexer-config type="folder" foldernameAsQualifier="true" filenameAsQualifier="true"/>
  </index>
</resources>
"@

    $configPath = Join-Path $tempDir "priconfig.xml"
    $configXml | Out-File -Encoding UTF8 $configPath

    # Generate a minimal resources.pri with "ghostty" as the resource map name
    $outputPri = Join-Path $OutputDir "resources.pri"

    & $makepri.FullName new /cf $configPath /pr $tempDir /mn "ghostty" /of $outputPri /o 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "makepri new failed (exit code $LASTEXITCODE). Trying alternative approach..."

        # Alternative: just copy the framework .pri as-is (better than nothing)
        $fwPri = Join-Path $runtimeDir.FullName "resources.pri"
        if (Test-Path $fwPri) {
            Copy-Item $fwPri $outputPri -Force
            Write-Host "Copied framework resources.pri as fallback"
        }
    } else {
        Write-Host "Generated resources.pri successfully"
    }

    # Also copy the framework-specific .pri files (Microsoft.UI.pri, etc.)
    foreach ($pri in @("Microsoft.UI.pri", "Microsoft.UI.Xaml.Controls.pri")) {
        $src = Join-Path $runtimeDir.FullName $pri
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $OutputDir $pri) -Force
            Write-Host "Copied $pri"
        }
    }
} finally {
    # Cleanup temp directory
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PRI generation complete"
