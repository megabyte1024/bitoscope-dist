# SPDX-License-Identifier: MIT

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'dist.ps1')
. (Join-Path $PSScriptRoot 'msi.ps1')
. (Join-Path $PSScriptRoot 'iexpress.ps1')

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Count = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:Count++
    try {
        & $Body
        Write-Host "ok    $Name"
    } catch {
        $script:Failures.Add("$Name : $_")
        Write-Host "FAIL  $Name : $_"
    }
}

function Assert-Equal($Expected, $Actual, [string]$What = 'value') {
    $left = ($Expected | ForEach-Object { "$_" }) -join '|'
    $right = ($Actual | ForEach-Object { "$_" }) -join '|'
    if ($left -cne $right) { throw "$What expected [$left], got [$right]" }
}

function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body } catch {
        if ("$_" -notmatch $Pattern) { throw "error '$_' does not match '$Pattern'" }
        return
    }
    throw "no error, expected one matching '$Pattern'"
}

function New-TempFolder {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("bitoscope-dist-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function New-NameSet { return , [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }

Test-Case 'valid 8.3 name is kept alone' {
    Assert-Equal 'demo.exe' (Get-MsiFileName 'demo.exe' (New-NameSet))
}

Test-Case 'long names get numbered short names in order' {
    $taken = New-NameSet
    Assert-Equal 'FX2LAF~1.FW|fx2lafw-a.fw' (Get-MsiFileName 'fx2lafw-a.fw' $taken)
    Assert-Equal 'FX2LAF~2.FW|fx2lafw-b.fw' (Get-MsiFileName 'fx2lafw-b.fw' $taken)
}

Test-Case 'short name drops characters 8.3 forbids' {
    Assert-Equal 'GOOGLE~1.TTF|Google Sans[wght].ttf' (Get-MsiFileName 'Google Sans[wght].ttf' (New-NameSet))
}

Test-Case 'short name taken by real 8.3 name is not reused' {
    $taken = New-NameSet
    [void]$taken.Add('LIBSIG~1.DLL')
    Assert-Equal 'LIBSIG~2.DLL|libsigrok-4.dll' (Get-MsiFileName 'libsigrok-4.dll' $taken)
}

Test-Case 'tenth short name keeps eight characters' {
    $taken = New-NameSet
    $names = foreach ($i in 1..10) { Get-MsiFileName "longfilename$i.txt" $taken }
    Assert-Equal 'LONGF~10.TXT|longfilename10.txt' $names[9]
}

Test-Case 'idt text has header lines, empty null and CRLF' {
    $table = New-MsiTable 'Property' @('Property', 'Value') @('s72', 'l0') @('Property')
    Add-MsiRow $table @('A', $null)
    Assert-Equal "Property`tValue`r`ns72`tl0`r`nProperty`tProperty`r`nA`t`r`n" (ConvertTo-IdtText $table)
}

Test-Case 'idt refuses tab in value' {
    $table = New-MsiTable 'Property' @('Property', 'Value') @('s72', 'l0') @('Property')
    Add-MsiRow $table @('A', "x`ty")
    Assert-Throws { ConvertTo-IdtText $table } 'tab or line break'
}

Test-Case 'row with wrong column count is refused' {
    $table = New-MsiTable 'Property' @('Property', 'Value') @('s72', 'l0') @('Property')
    Assert-Throws { Add-MsiRow $table @('A') } 'has 2 columns'
}

function New-TestProduct {
    return [pscustomobject]@{
        Name = 'Bitoscope'; Folder = 'Bitoscope'; Version = '1.2.3'; Manufacturer = 'Test'
        UpgradeCode = '{140CE35C-0B96-4A07-83C9-03B4E1B59042}'
        ProductCode = '{00000000-0000-0000-0000-000000000001}'; PackageCode = '{00000000-0000-0000-0000-000000000002}'
        Url = 'https://example.invalid'; Program = 'bitoscope_gui.exe'; Cabinet = 'bitoscope.cab'
    }
}

function New-TestStage([string]$Root) {
    $files = @('bitoscope_gui.exe', 'drivers\demo.exe', 'drivers\sigrok-firmware\fx2lafw-a.fw',
        'drivers\sigrok-firmware\fx2lafw-b.fw', 'assets\fonts\Google Sans[wght].ttf')
    foreach ($relative in $files) {
        $path = Join-Path $Root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllText($path, "content of $relative")
    }
}

Test-Case 'msi tables list every file once, in cabinet order' {
    $root = New-TempFolder
    try {
        New-TestStage $root
        $files = Get-StageFiles $root
        $model = New-MsiTables (New-TestProduct) $files
        $fileTable = @($model.Tables | Where-Object { $_.Name -eq 'File' })[0]
        Assert-Equal $files.Count $fileTable.Rows.Count 'file rows'
        Assert-Equal ($model.Cabinet | ForEach-Object { $_.Key }) ($fileTable.Rows | ForEach-Object { $_[0] }) 'cabinet order'
        Assert-Equal (1..$files.Count) ($fileTable.Rows | ForEach-Object { $_[7] }) 'sequence'
        $media = @($model.Tables | Where-Object { $_.Name -eq 'Media' })[0]
        Assert-Equal $files.Count $media.Rows[0][1] 'last sequence'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'component GUID depends on path only' {
    Assert-Equal (Get-StableGuid 'drivers\demo.exe') (Get-StableGuid 'DRIVERS\demo.exe')
    if ((Get-StableGuid 'drivers\demo.exe') -eq (Get-StableGuid 'drivers\demo2.exe')) { throw 'two paths share GUID' }
    if ((Get-StableGuid 'a') -notmatch '^\{[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\}$') { throw 'GUID format' }
}

Test-Case 'msi tables need program' {
    $root = New-TempFolder
    try {
        New-TestStage $root
        Remove-Item -LiteralPath (Join-Path $root 'bitoscope_gui.exe')
        Assert-Throws { New-MsiTables (New-TestProduct) (Get-StageFiles $root) } 'stage holds no bitoscope_gui.exe'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'msi extracts to same files by administrative install' {
    $root = New-TempFolder
    try {
        $stage = Join-Path $root 'stage'
        New-TestStage $stage
        $msi = Join-Path $root 'test.msi'
        New-MsiPackage -Stage $stage -OutputPath $msi -WorkFolder (Join-Path $root 'work') -Product (New-TestProduct)
        Assert-Equal '1.2.3' (Invoke-MsiQuery $msi "SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductVersion'")
        $target = Join-Path $root 'admin'
        $process = Start-Process -FilePath msiexec.exe -ArgumentList "/a `"$msi`" /qn TARGETDIR=`"$target`"" -Wait -PassThru
        Assert-Equal 0 $process.ExitCode 'msiexec /a exit code'
        foreach ($file in Get-StageFiles $stage) {
            $extracted = Join-Path $target "Bitoscope\$($file.Relative)"
            Assert-Equal "content of $($file.Relative)" ([System.IO.File]::ReadAllText($extracted)) $file.Relative
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'setup program carries msi unchanged' {
    $root = New-TempFolder
    try {
        $stage = Join-Path $root 'stage'
        New-TestStage $stage
        $msi = Join-Path $root 'test.msi'
        New-MsiPackage -Stage $stage -OutputPath $msi -WorkFolder (Join-Path $root 'work') -Product (New-TestProduct)
        $exe = Join-Path $root 'setup.exe'
        New-IExpressPackage -MsiPath $msi -OutputPath $exe -WorkFolder (Join-Path $root 'ie') -FriendlyName 'Test Setup'
        $process = Start-Process -FilePath $exe -ArgumentList "/C `"/T:$root\extract`" /Q" -Wait -PassThru
        Assert-Equal 0 $process.ExitCode 'extract exit code'
        Assert-Equal (Get-FileHash -LiteralPath $msi).Hash (Get-FileHash -LiteralPath "$root\extract\test.msi").Hash 'msi hash'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'SED starts msi without quotes and refuses names with spaces' {
    $text = ConvertTo-SedText 'C:\o\a.msi' 'C:\o\a.exe' 'A'
    if ($text -notmatch '(?m)^AppLaunched=msiexec\.exe /i a\.msi\r?$') { throw "AppLaunched line wrong:`n$text" }
    Assert-Throws { ConvertTo-SedText 'C:\o\a b.msi' 'C:\o\a.exe' 'A' } 'no spaces'
}

Test-Case 'arguments are quoted as Windows programs read them' {
    Assert-Equal 'a "b c" "" "d\"e" "f g\\"' (ConvertTo-ArgumentText @('a', 'b c', '', 'd"e', 'f g\'))
}

Test-Case 'dumpbin dependents are parsed, delay loads included' {
    $text = @"
Dump of file x.exe

File Type: EXECUTABLE IMAGE

  Image has the following dependencies:

    libusb-1.0.dll
    KERNEL32.dll

  Image has the following delay load dependencies:

    WINMM.dll

  Summary

        1000 .data
"@
    Assert-Equal @('libusb-1.0.dll', 'KERNEL32.dll', 'WINMM.dll') (ConvertFrom-DumpbinDependents $text)
}

Test-Case 'missing DLL is named, DLL beside, API set and system DLL are not' {
    $root = New-TempFolder
    try {
        New-Item -ItemType Directory -Path "$root\stage\drivers", "$root\system" | Out-Null
        foreach ($name in @('stage\drivers\a.exe', 'stage\drivers\beside.dll', 'system\kernel32.dll', 'system\vcruntime140.dll')) {
            [System.IO.File]::WriteAllText((Join-Path $root $name), '')
        }
        $imports = { param($path)
            if ($path -like '*a.exe') { @('beside.dll', 'KERNEL32.dll', 'api-ms-win-crt-heap-l1-1-0.dll', 'VCRUNTIME140.dll', 'gone.dll') }
            else { @() } }
        Assert-Equal @('drivers\a.exe needs VCRUNTIME140.dll, found nowhere it would be loaded from',
            'drivers\a.exe needs gone.dll, found nowhere it would be loaded from') `
            (Find-MissingDlls "$root\stage\" "$root\system" $imports)
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'Visual C++ runtime is copied beside each program, with its own needs' {
    $root = New-TempFolder
    try {
        New-Item -ItemType Directory -Path "$root\stage\decoders", "$root\crt" | Out-Null
        [System.IO.File]::WriteAllText("$root\stage\decoders\d.exe", '')
        foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'concrt140.dll')) { [System.IO.File]::WriteAllText("$root\crt\$name", $name) }
        $imports = { param($path)
            switch -Wildcard ($path) { '*d.exe' { @('MSVCP140.dll', 'KERNEL32.dll') } '*msvcp140.dll' { @('VCRUNTIME140.dll') } default { @() } } }
        $added = Add-VisualCppRuntime "$root\stage" "$root\crt" $imports
        Assert-Equal @('decoders\MSVCP140.dll', 'decoders\VCRUNTIME140.dll') $added
        if (Test-Path "$root\stage\decoders\concrt140.dll") { throw 'unneeded runtime DLL copied' }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'merge refuses same file with different content from two repos' {
    $root = New-TempFolder
    try {
        foreach ($name in @('a', 'b')) {
            New-Item -ItemType Directory -Path "$root\$name\drivers" | Out-Null
            [System.IO.File]::WriteAllText("$root\$name\drivers\same.dll", 'same')
            [System.IO.File]::WriteAllText("$root\$name\drivers\libusb-1.0.dll", "from $name")
        }
        Remove-Item "$root\b\drivers\libusb-1.0.dll"
        $owners = @{}
        Merge-Tree "$root\a" "$root\stage" 'repo-a' $owners
        Merge-Tree "$root\b" "$root\stage" 'repo-b' $owners
        [System.IO.File]::WriteAllText("$root\b\drivers\libusb-1.0.dll", 'from b')
        Assert-Throws { Merge-Tree "$root\b" "$root\stage" 'repo-b' $owners } 'installed by repo-a and repo-b'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'plugin missing from listing is named' {
    $listing = "demo: 1 device`r`n  demo-0  Demo device`r`nsigrok_bridge: no device`r`n"
    Assert-Equal @('fnirsi_dla') (Find-UnlistedPlugins @('demo', 'fnirsi_dla', 'sigrok_bridge') $listing)
    Assert-Equal @('demo') (Find-UnlistedPlugins @('demo') 'demo-extra: x')
}

Test-Case 'manifest needs every repo with full commit' {
    $root = New-TempFolder
    try {
        $path = Join-Path $root 'manifest.json'
        $good = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest.json') -Raw
        [System.IO.File]::WriteAllText($path, $good)
        Assert-Equal 3 @((Read-Manifest $path).repos).Count 'repo count'
        [System.IO.File]::WriteAllText($path, ($good -replace '"commit": "([0-9a-f]{8})[0-9a-f]{32}"', '"commit": "$1"'))
        Assert-Throws { Read-Manifest $path } 'commit of bitoscope is not 40 hex digits'
        [System.IO.File]::WriteAllText($path, ($good -replace '"version": "[^"]+"', '"version": "0.4"'))
        Assert-Throws { Read-Manifest $path } 'not MAJOR.MINOR.PATCH'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

function New-NightlyManifestText {
    return @'
{
  "version": "0.4.26324",
  "nightly": true,
  "repos": [
    {"name": "bitoscope", "url": "https://example.invalid/a.git", "branch": "main", "commit": "1111111111111111111111111111111111111111"},
    {"name": "bitoscope-fnirsi-dla", "url": "https://example.invalid/b.git", "branch": "main", "commit": "2222222222222222222222222222222222222222"},
    {"name": "bitoscope-sigrok-bridge", "url": "https://example.invalid/c.git", "branch": "main", "commit": "3333333333333333333333333333333333333333"}
  ]
}
'@
}

Test-Case 'manifest takes branch instead of tag' {
    $root = New-TempFolder
    try {
        $path = Join-Path $root 'manifest.json'
        [System.IO.File]::WriteAllText($path, (New-NightlyManifestText))
        $data = Read-Manifest $path
        Assert-Equal 'main' (Get-ManifestRepo $data 'bitoscope').branch
        [System.IO.File]::WriteAllText($path, ((New-NightlyManifestText) -replace '"branch": "main", ', ''))
        Assert-Throws { Read-Manifest $path } 'needs url and tag or branch'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'release and nightly have own names and upgrade codes' {
    $root = New-TempFolder
    try {
        $path = Join-Path $root 'manifest.json'
        [System.IO.File]::WriteAllText($path, (New-NightlyManifestText))
        $nightly = Get-Naming (Read-Manifest $path)
        $release = Get-Naming (Read-Manifest (Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest.json'))
        Assert-Equal 'Bitoscope Nightly' $nightly.Name
        Assert-Equal 'bitoscope-nightly' $nightly.Base
        Assert-Equal 'Bitoscope' $release.Name
        if ($release.Base -notmatch '^bitoscope-\d+\.\d+\.\d+$') { throw "release base $($release.Base)" }
        if ($release.UpgradeCode -eq $nightly.UpgradeCode) { throw 'release and nightly share upgrade code' }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "$($script:Failures.Count) of $($script:Count) tests failed:"
    $script:Failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "All $($script:Count) tests passed."
