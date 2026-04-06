$ErrorActionPreference = "Stop"

$systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
$userHome = if ($env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOMEDRIVE -and $env:HOMEPATH) {
    "$($env:HOMEDRIVE)$($env:HOMEPATH)"
} elseif ($env:USERNAME) {
    Join-Path $systemDrive "Users\$($env:USERNAME)"
} else {
    Join-Path $systemDrive "Users"
}

$zigExe = if ($env:ZIG_HOME -and (Test-Path (Join-Path $env:ZIG_HOME "zig.exe"))) {
    Join-Path $env:ZIG_HOME "zig.exe"
} else {
    "zig.exe"
}

$globalCacheDir = if ($env:ZIG_GLOBAL_CACHE_DIR) {
    $env:ZIG_GLOBAL_CACHE_DIR
} else {
    Join-Path $userHome "AppData\Local\zig"
}

$downloadDir = Join-Path (Get-Location) ".zig-cache\downloads"
New-Item -ItemType Directory -Force -Path $globalCacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$deps = @(
    @{ Url = "https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz"; File = "libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/vaxis-7dbb9fd3122e4ffad262dd7c151d80d863b68558.tar.gz"; File = "vaxis-7dbb9fd3122e4ffad262dd7c151d80d863b68558.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz"; File = "z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zig_objc-f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae.tar.gz"; File = "zig_objc-f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zig_js-04db83c617da1956ac5adc1cb9ba1e434c1cb6fd.tar.gz"; File = "zig_js-04db83c617da1956ac5adc1cb9ba1e434c1cb6fd.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz"; File = "uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zig_wayland-1b5c038ec10da20ed3a15b0b2a6db1c21383e8ea.tar.gz"; File = "zig_wayland-1b5c038ec10da20ed3a15b0b2a6db1c21383e8ea.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zf-3c52637b7e937c5ae61fd679717da3e276765b23.tar.gz"; File = "zf-3c52637b7e937c5ae61fd679717da3e276765b23.tar.gz" },
    @{ Url = "https://github.com/ivanstepanovftw/zigimg/archive/d7b7ab0ba0899643831ef042bd73289510b39906.tar.gz"; File = "zigimg-d7b7ab0ba0899643831ef042bd73289510b39906.tar.gz" },
    @{ Url = "https://mirrors.lug.mtu.edu/gentoo/distfiles/59/uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM.tar.gz"; File = "uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/gobject-2025-11-08-23-1.tar.zst"; File = "gobject-2025-11-08-23-1.tar.zst" },
    @{ Url = "https://deps.files.ghostty.org/wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz"; File = "wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz" },
    @{ Url = "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.47/wayland-protocols-1.47.tar.gz"; File = "wayland-protocols-1.47.tar.gz"; Optional = $true },
    @{ Url = "https://deps.files.ghostty.org/plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz"; File = "plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz"; File = "JetBrainsMono-2.304.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz"; File = "NerdFontsSymbolsOnly-3.4.0.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/ghostty-themes-release-20260323-152405-a2c7b60.tgz"; File = "ghostty-themes-release-20260323-152405-a2c7b60.tgz" },
    @{ Url = "https://deps.files.ghostty.org/breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz"; File = "breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz"; File = "DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz" },
    @{ Url = "https://github.com/ocornut/imgui/archive/refs/tags/v1.92.5-docking.tar.gz"; File = "imgui-v1.92.5-docking.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/fontconfig-2.14.2.tar.gz"; File = "fontconfig-2.14.2.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz"; File = "freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz"; File = "glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/gtk4-layer-shell-1.1.0.tar.gz"; File = "gtk4-layer-shell-1.1.0.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/wayland-protocols-258d8f88f2c8c25a830c6316f87d23ce1a0f12d9.tar.gz"; File = "wayland-protocols-258d8f88f2c8c25a830c6316f87d23ce1a0f12d9.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/harfbuzz-11.0.0.tar.xz"; File = "harfbuzz-11.0.0.tar.xz" },
    @{ Url = "https://deps.files.ghostty.org/highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz"; File = "highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/gettext-0.24.tar.gz"; File = "gettext-0.24.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz"; File = "libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/libxml2-2.11.5.tar.gz"; File = "libxml2-2.11.5.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz"; File = "oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz"; File = "sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz"; File = "spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/utfcpp-1220d4d18426ca72fc2b7e56ce47273149815501d0d2395c2a98c726b31ba931e641.tar.gz"; File = "utfcpp-1220d4d18426ca72fc2b7e56ce47273149815501d0d2395c2a98c726b31ba931e641.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/wuffs-122037b39d577ec2db3fd7b2130e7b69ef6cc1807d68607a7c232c958315d381b5cd.tar.gz"; File = "wuffs-122037b39d577ec2db3fd7b2130e7b69ef6cc1807d68607a7c232c958315d381b5cd.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz"; File = "pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz"; File = "zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz" }
)

function Invoke-Seed {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Dep
    )

    $archive = Join-Path $downloadDir $Dep.File
    $label = $Dep.File
    if ($Dep.Optional) {
        $label = "$label (optional)"
    }
    Write-Host "== $label =="

    if (-not (Test-Path $archive)) {
        & bitsadmin /transfer "winghostty-$($Dep.File)" /download /priority foreground $Dep.Url $archive
        if ($LASTEXITCODE -ne 0) {
            if ($Dep.Optional) {
                Write-Host "Skipping optional dependency archive: $($Dep.File)"
                return
            }

            throw "bitsadmin failed for $($Dep.Url)"
        }
    }

    & $zigExe fetch --global-cache-dir $globalCacheDir $archive
    if ($LASTEXITCODE -ne 0) {
        if ($Dep.Optional) {
            Write-Host "Skipping optional dependency seed: $($Dep.File)"
            return
        }

        throw "zig fetch failed for $archive"
    }
}

foreach ($dep in $deps) {
    Invoke-Seed $dep
}

Write-Host "Seeded Zig cache under `"$globalCacheDir`""
