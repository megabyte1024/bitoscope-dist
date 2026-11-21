# SPDX-License-Identifier: MIT

[CmdletBinding()]
param(
    [ValidateSet('all', 'fetch', 'build', 'stage', 'package', 'install-test')]
    [string]$Target = 'all',
    [string]$Manifest = '',
    [string]$Work = '',
    [string]$Out = '',
    [ValidateSet('zip', 'msi', 'exe')]
    [string[]]$Formats = @('zip', 'msi', 'exe'),
    [string]$VcpkgRoot = '',
    [string]$Msys2Root = 'C:\msys64'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'dist.ps1')
. (Join-Path $PSScriptRoot 'msi.ps1')
. (Join-Path $PSScriptRoot 'iexpress.ps1')

$Manufacturer = 'Bitoscope project'
$ProjectUrl = 'https://github.com/megabyte1024/bitoscope'
$Repos = [ordered]@{ main = 'bitoscope'; dla = 'bitoscope-fnirsi-dla'; bridge = 'bitoscope-sigrok-bridge' }

function Get-VcpkgRoot {
    foreach ($candidate in @($VcpkgRoot, $env:VCPKG_ROOT, $env:VCPKG_INSTALLATION_ROOT, 'C:\vcpkg')) {
        if (-not [string]::IsNullOrEmpty($candidate) -and (Test-Path -LiteralPath (Join-Path $candidate 'vcpkg.exe'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'no vcpkg found: install it into C:\vcpkg, set VCPKG_ROOT or pass -VcpkgRoot'
}

function Assert-BuildTools([string]$Vcpkg) {
    $problems = @()
    foreach ($tool in @('cmake', 'git')) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) { $problems += "program not found: $tool" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Vcpkg 'installed\x64-windows\lib\libusb-1.0.lib'))) {
        $problems += "vcpkg at $Vcpkg has no libusb: $Vcpkg\vcpkg.exe install libusb:x64-windows"
    }
    $bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash) -or -not (Test-Path -LiteralPath (Join-Path $Msys2Root 'ucrt64\bin\gcc.exe'))) {
        $problems += "no MSYS2 with UCRT64 toolchain at $Msys2Root (bridge builds libsigrok with it): " +
            'pacman -S --needed base-devel mingw-w64-ucrt-x86_64-{gcc,autotools,pkgconf,tools-git,ntldd}'
    }
    if ($problems.Count -gt 0) { throw "cannot start:`n  $($problems -join "`n  ")" }
}

function Get-Source([string]$Key) { return Join-Path $Work "src\$($Repos[$Key])" }

function Invoke-Fetch($Data) {
    foreach ($key in $Repos.Keys) {
        Sync-Repo (Get-ManifestRepo $Data $Repos[$key]) (Get-Source $key) (Join-Path $Work 'logs')
    }
}

function Invoke-CMakeProject([string]$Key, [string[]]$DepsOptions, [string[]]$Options) {
    $source = Get-Source $Key
    $logs = Join-Path $Work 'logs'
    Invoke-Step "Configure $key third-party libraries" 'cmake' (@('-S', "$source\third_party", '-B', "$source\build-deps") + $DepsOptions) -Logs $logs
    Invoke-Step "Build $key third-party libraries" 'cmake' @('--build', "$source\build-deps", '--config', 'Release', '--target', 'install') -Logs $logs
    Invoke-Step "Configure $key" 'cmake' (@('-S', $source, '-B', "$source\build", '-DCMAKE_CONFIGURATION_TYPES=Release') + $Options) -Logs $logs
    Invoke-Step "Build $key" 'cmake' @('--build', "$source\build", '--config', 'Release') -Logs $logs
}

function Invoke-Build {
    $vcpkg = Get-VcpkgRoot
    Assert-BuildTools $vcpkg
    $logs = Join-Path $Work 'logs'
    $toolchain = Join-Path $vcpkg 'scripts\buildsystems\vcpkg.cmake'

    $bridge = Get-Source 'bridge'
    $msys2 = @{ MSYSTEM = 'UCRT64'; CHERE_INVOKING = '1' }
    $bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
    Invoke-Step 'Install bridge libraries with vcpkg' "$env:SystemRoot\System32\cmd.exe" @('/c', "$bridge\scripts\install_msvc_dlls.cmd") `
        -WorkingDirectory $bridge -Environment @{ VCPKG_ROOT = $vcpkg } -Logs $logs
    Invoke-Step 'Configure bridge' 'cmake' @('-S', $bridge, '-B', "$bridge\build") -Logs $logs
    Invoke-Step 'Build bridge USB shim' 'cmake' @('--build', "$bridge\build", '--config', 'Release', '--target', 'bridge_usb') -Logs $logs
    Invoke-Step 'Build libsigrok' $bash @('-lc', 'sh scripts/build_libsigrok.sh') -WorkingDirectory $bridge -Environment $msys2 -Logs $logs
    if (-not (Test-Path -Path "$bridge\third_party\sigrok-firmware\*.fw")) {
        Invoke-Step 'Fetch sigrok firmware' $bash @('-lc', 'sh scripts/fetch_sigrok_firmware.sh') -WorkingDirectory $bridge `
            -Environment $msys2 -Logs $logs
    }
    Invoke-Step 'Configure bridge with libsigrok' 'cmake' @('-S', $bridge, '-B', "$bridge\build") -Logs $logs
    Invoke-Step 'Build bridge' 'cmake' @('--build', "$bridge\build", '--config', 'Release') -Logs $logs

    Invoke-CMakeProject 'dla' @() @("-DCMAKE_TOOLCHAIN_FILE=$toolchain")
    $main = Get-Source 'main'
    Invoke-CMakeProject 'main' @("-DCMAKE_INSTALL_PREFIX=$main\deps") @('-DBITOSCOPE_GUI_TEST_HOOK=OFF')
}

function Get-StageFolder($Data) { return Join-Path $Work "stage\$($Naming.Base)" }

function Copy-License([string]$Source, [string]$Licenses, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "licence file $Source is missing" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $Licenses $Name)
}

function Write-Sources($Data, [string]$Licenses, [string]$Vcpkg) {
    $bridge = Get-Source 'bridge'
    $lines = @(
        "$($Naming.Name) $($Data.version) for Windows x64 is built from these sources:",
        '')
    foreach ($key in $Repos.Keys) {
        $repo = Get-ManifestRepo $Data $Repos[$key]
        $lines += "$($repo.name): $($repo.url), $(Get-RefText $repo), commit $($repo.commit)"
    }
    $libsigrok = Get-GitOutput "$bridge\third_party\libsigrok" @('rev-parse', 'HEAD')
    $vcpkgCommit = Get-GitOutput $Vcpkg @('rev-parse', 'HEAD')
    $lines += @(
        "libsigrok: https://github.com/sigrokproject/libsigrok.git, commit $libsigrok",
        'fx2lafw firmware: https://sigrok.org/download/binary/sigrok-firmware-fx2lafw/ (version named in bitoscope-sigrok-bridge scripts/fetch_sigrok_firmware.sh)',
        "glib, libzip, libusb and libraries they use: vcpkg ports, https://github.com/microsoft/vcpkg.git, commit $vcpkgCommit",
        'MinGW runtime of libsigrok (libgcc, libwinpthread): MSYS2 UCRT64 packages, https://packages.msys2.org',
        '',
        'bitoscope-sigrok-bridge and libsigrok are licensed under GPL-3.0-or-later; their complete source is at',
        'addresses above, at commits named there.')
    [System.IO.File]::WriteAllLines((Join-Path $Licenses 'SOURCES.txt'), $lines, [System.Text.Encoding]::ASCII)
}

function Invoke-Stage($Data) {
    $vcpkg = Get-VcpkgRoot
    $vs = Get-VisualStudio
    $stage = Get-StageFolder $Data
    $installs = Join-Path $Work 'install'
    foreach ($folder in @($stage, $installs)) {
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $owners = @{}
    foreach ($key in @('main', 'dla', 'bridge')) {
        $source = Get-Source $key
        if (-not (Test-Path -LiteralPath "$source\build\CMakeCache.txt")) { throw "$($Repos[$key]) is not built: run target build first" }
        $prefix = Join-Path $installs $key
        Invoke-Step "Install $key" 'cmake' @('--install', "$source\build", '--config', 'Release', '--prefix', $prefix) -Logs (Join-Path $Work 'logs')
        Merge-Tree $prefix $stage $Repos[$key] $owners
    }

    $checker = Join-Path $Work 'checker'
    if (Test-Path -LiteralPath $checker) { Remove-Item -LiteralPath $checker -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $checker | Out-Null
    Move-Item -LiteralPath (Join-Path $stage 'bitoscope_cli.exe') -Destination $checker
    Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.pdb' | Remove-Item -Force

    $licenses = Join-Path $stage 'licenses'
    $bridge = Get-Source 'bridge'
    Copy-License (Join-Path (Get-Source 'dla') 'LICENSE') $licenses 'fnirsi_dla-LICENSE.txt'
    Copy-License (Join-Path $bridge 'COPYING') $licenses 'sigrok_bridge-COPYING.txt'
    Copy-License (Join-Path $bridge 'third_party\libsigrok\COPYING') $licenses 'libsigrok-COPYING.txt'
    foreach ($port in Get-ChildItem -LiteralPath "$bridge\third_party\vcpkg_installed\x64-windows\share" -Directory) {
        $copyright = Join-Path $port.FullName 'copyright'
        if ($port.Name -notlike 'vcpkg-*' -and (Test-Path -LiteralPath $copyright)) {
            Copy-License $copyright $licenses "$($port.Name)-copyright.txt"
        }
    }
    foreach ($package in @('libgcc', 'libwinpthread')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Msys2Root "ucrt64\share\licenses\$package") -File) {
            Copy-License $file.FullName $licenses "mingw-$package-$($file.Name).txt"
        }
    }
    Write-Sources $Data $licenses $vcpkg

    Write-Host '==> Add Visual C++ runtime beside programs'
    $added = Add-VisualCppRuntime $stage $vs.Runtime (New-ImportsReader $vs.Dumpbin)
    Write-Host "    $($added.Count) files from $($vs.Runtime)"

    Test-Distribution $stage (Join-Path $checker 'bitoscope_cli.exe') $vs.Dumpbin (Join-Path $Work 'home')
    Write-Host "Distribution folder $stage is ready ($(@(Get-Plugins $stage).Count) plugins)."
}

function Get-Product($Data) {
    return [pscustomobject]@{
        Name = $Naming.Name
        Folder = $Naming.Name
        Version = $Data.version
        Manufacturer = $Manufacturer
        UpgradeCode = $Naming.UpgradeCode
        ProductCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        PackageCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        Url = $ProjectUrl
        Program = 'bitoscope_gui.exe'
        Cabinet = 'bitoscope.cab'
    }
}

function Get-PackagePath($Data, [string]$Format) {
    $base = Join-Path $Out "$($Naming.Base)-windows-x64"
    switch ($Format) {
        'zip' { return "$base.zip" }
        'msi' { return "$base.msi" }
        'exe' { return "$base-setup.exe" }
    }
}

function Invoke-Package($Data) {
    $stage = Get-StageFolder $Data
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'bitoscope_gui.exe'))) { throw "no distribution folder at ${stage}: run target stage first" }
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $msi = Get-PackagePath $Data 'msi'
    if ('zip' -in $Formats) {
        $zip = Get-PackagePath $Data 'zip'
        Write-Host "==> Zip $zip"
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    }
    if ('msi' -in $Formats -or 'exe' -in $Formats) {
        Write-Host "==> Windows Installer package $msi"
        New-MsiPackage -Stage $stage -OutputPath $msi -WorkFolder (Join-Path $Work 'msi') -Product (Get-Product $Data)
    }
    if ('exe' -in $Formats) {
        $exe = Get-PackagePath $Data 'exe'
        Write-Host "==> Setup program $exe"
        New-IExpressPackage -MsiPath $msi -OutputPath $exe -WorkFolder (Join-Path $Work 'iexpress') `
            -FriendlyName "$($Naming.Name) $($Data.version) Setup"
        if ('msi' -notin $Formats) { Remove-Item -LiteralPath $msi -Force }
    }
    Get-ChildItem -LiteralPath $Out -File | ForEach-Object { Write-Host ("    {0}  {1:N0} bytes" -f $_.Name, $_.Length) }
}

function Test-Installed([string]$Stage, [string]$Folder, [string]$Checker, [string]$Dumpbin, [string]$What) {
    $expected = @(Get-ChildItem -LiteralPath $Stage -Recurse -File).Count
    $found = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($found -ne $expected) { throw "$What installed $found files into $Folder, distribution has $expected" }
    $shortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$($Naming.Name).lnk"
    if (-not (Test-Path -LiteralPath $shortcut)) { throw "$What made no Start menu entry $shortcut" }
    Test-Distribution $Folder $Checker $Dumpbin (Join-Path $Work 'home')
}

function Invoke-Msiexec([string[]]$Arguments, [string]$What) {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList (ConvertTo-ArgumentText $Arguments) -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$What failed: msiexec exited $($process.ExitCode)" }
}

function Invoke-InstallTest($Data) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'install-test installs into Program Files: run it as administrator (GitHub runner does)'
    }
    $stage = Get-StageFolder $Data
    $checker = Join-Path $Work 'checker\bitoscope_cli.exe'
    $vs = Get-VisualStudio
    $folder = Join-Path $env:ProgramFiles $Naming.Name
    $logs = Join-Path $Work 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $msi = Get-PackagePath $Data 'msi'
    $exe = Get-PackagePath $Data 'exe'
    if (Test-Path -LiteralPath $folder) { throw "$folder exists already: uninstall $($Naming.Name) first" }

    if (Test-Path -LiteralPath $msi) {
        Write-Host "==> Install $msi"
        Invoke-Msiexec @('/i', $msi, '/qn', '/l*v', (Join-Path $logs 'msi-install.log')) 'msi install'
        Test-Installed $stage $folder $checker $vs.Dumpbin 'msi'
        Write-Host "==> Uninstall $msi"
        Invoke-Msiexec @('/x', $msi, '/qn', '/l*v', (Join-Path $logs 'msi-uninstall.log')) 'msi uninstall'
        if (Test-Path -LiteralPath $folder) { throw "msi uninstall left $folder" }
    }
    if (Test-Path -LiteralPath $exe) {
        Write-Host "==> Install $exe"
        $process = Start-Process -FilePath $exe -ArgumentList '/Q' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "setup program exited $($process.ExitCode)" }
        Test-Installed $stage $folder $checker $vs.Dumpbin 'setup program'
        Write-Host "==> Uninstall $($Naming.Name) installed by setup program"
        $installed = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
            Where-Object { $_.GetValue('DisplayName') -eq $Naming.Name } | ForEach-Object { $_.PSChildName })
        if ($installed.Count -ne 1) { throw "expected one installed $($Naming.Name), found $($installed.Count)" }
        Invoke-Msiexec @('/x', $installed[0], '/qn', '/l*v', (Join-Path $logs 'exe-uninstall.log')) 'uninstall after setup program'
        if (Test-Path -LiteralPath $folder) { throw "uninstall left $folder" }
    }
    Write-Host 'Install test passed.'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($Manifest -eq '') { $Manifest = Join-Path $RepoRoot 'manifest.json' }
if ($Work -eq '') { $Work = Join-Path $RepoRoot 'work\windows' }
if ($Out -eq '') { $Out = Join-Path $RepoRoot 'out' }
$data = Read-Manifest $Manifest
$Naming = Get-Naming $data
$Work = [System.IO.Path]::GetFullPath($Work)
$Out = [System.IO.Path]::GetFullPath($Out)
switch ($Target) {
    'fetch' { Invoke-Fetch $data }
    'build' { Invoke-Build }
    'stage' { Invoke-Stage $data }
    'package' { Invoke-Package $data }
    'install-test' { Invoke-InstallTest $data }
    'all' {
        Invoke-Fetch $data
        Invoke-Build
        Invoke-Stage $data
        Invoke-Package $data
    }
}
