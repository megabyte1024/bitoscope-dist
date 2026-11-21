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

Test-Case 'component ids differ between products and stay equal between versions of one product' {
    $root = New-TempFolder
    try {
        New-TestStage $root
        $files = Get-StageFiles $root
        function Get-ComponentIds($product) {
            $table = @((New-MsiTables $product $files).Tables | Where-Object { $_.Name -eq 'Component' })[0]
            return @($table.Rows | ForEach-Object { $_[1] })
        }
        $release = New-TestProduct
        $nightly = New-TestProduct
        $nightly.UpgradeCode = '{5B0F5448-17C3-4625-8FE1-DB6713DEBC75}'
        $later = New-TestProduct
        $later.Version = '1.2.4'
        $shared = @(Get-ComponentIds $release | Where-Object { (Get-ComponentIds $nightly) -contains $_ }).Count
        Assert-Equal 0 $shared 'component ids shared by release and nightly'
        Assert-Equal (Get-ComponentIds $release) (Get-ComponentIds $later) 'component ids of two versions of one product'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

function New-UniqueTestProduct {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $product = New-TestProduct
    $product.Name = "Bitoscope Test $id"
    $product.Folder = "BitoscopeTest$id"
    $product.UpgradeCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $product.ProductCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $product.PackageCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    return $product
}

function Find-UserUninstallEntry([string]$Name) {
    $found = foreach ($hive in 'HKCU:', 'HKLM:') {
        Get-ChildItem "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
            Where-Object { $_.GetValue('DisplayName') -eq $Name }
    }
    return @($found)
}

function Invoke-TestMsiexec([string[]]$Arguments) {
    $process = Invoke-ProgramAndWait @{ FilePath = "$env:SystemRoot\System32\msiexec.exe"; ArgumentList = (ConvertTo-MsiexecArguments $Arguments) }
    return $process.ExitCode
}

Test-Case 'msiexec arguments quote property values the way msiexec reads them' {
    Assert-Equal 'INSTALLFOLDER="C:\a b\c" /qn /i "C:\x y\p.msi" PLAIN=1' (ConvertTo-MsiexecArguments @('INSTALLFOLDER=C:\a b\c\', '/qn', '/i', 'C:\x y\p.msi', 'PLAIN=1'))
}

Test-Case 'silent install without properties is per machine when elevated (not elevated: needs MSIINSTALLPERUSER=1)' {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) { Write-Host '      skipped: not elevated (a silent install then needs MSIINSTALLPERUSER=1, as the per-user tests give it)'; return }
    $root = New-TempFolder
    $product = New-UniqueTestProduct
    $msi = Join-Path $root 'test.msi'
    $userFolder = Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)"
    $machineFolder = Join-Path $env:ProgramFiles $product.Folder
    try {
        New-TestStage (Join-Path $root 'stage')
        New-MsiPackage -Stage (Join-Path $root 'stage') -OutputPath $msi -WorkFolder (Join-Path $root 'work') -Product $product
        Assert-Equal 0 (Invoke-TestMsiexec @('/i', $msi, '/qn', '/l*v', (Join-Path $root 'install.log'))) 'silent install exit code'
        $expected = if ($elevated) { $machineFolder } else { $userFolder }
        $other = if ($elevated) { $userFolder } else { $machineFolder }
        if (-not (Test-Path -LiteralPath (Join-Path $expected 'bitoscope_gui.exe'))) { throw "no bitoscope_gui.exe in $expected (elevated: $elevated)" }
        if (Test-Path -LiteralPath $other) { throw "install also made $other" }
        Assert-Equal 0 (Invoke-TestMsiexec @('/x', $msi, '/qn')) 'uninstall exit code'
        if (Test-Path -LiteralPath (Join-Path $expected 'bitoscope_gui.exe')) { throw "uninstall left files in $expected" }
    } finally {
        [void](Invoke-TestMsiexec @('/x', $product.ProductCode, '/qn'))
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $userFolder -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $machineFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Use-PerUserInstall([scriptblock]$Check, [string[]]$ExtraProperties = @()) {
    $root = New-TempFolder
    $product = New-UniqueTestProduct
    $msi = Join-Path $root 'test.msi'
    $shortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$($product.Name).lnk"
    try {
        New-TestStage (Join-Path $root 'stage')
        New-MsiPackage -Stage (Join-Path $root 'stage') -OutputPath $msi -WorkFolder (Join-Path $root 'work') -Product $product
        Assert-Equal 0 (Invoke-TestMsiexec (@('/i', $msi, '/qn', 'MSIINSTALLPERUSER=1', '/l*v', (Join-Path $root 'install.log')) + $ExtraProperties)) 'per-user install exit code'
        & $Check $root $product $shortcut
        Assert-Equal 0 (Invoke-TestMsiexec @('/x', $msi, '/qn', '/l*v', (Join-Path $root 'uninstall.log'))) 'uninstall exit code'
        Assert-Equal 0 @(Find-UserUninstallEntry $product.Name).Count 'uninstall entries after uninstall'
        if (Test-Path -LiteralPath $shortcut) { throw "uninstall left $shortcut" }
        $defaultFolder = Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)"
        if (@(Get-ChildItem -LiteralPath $defaultFolder -Recurse -File -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw "uninstall left files in $defaultFolder" }
    } finally {
        [void](Invoke-TestMsiexec @('/x', $product.ProductCode, '/qn'))
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)") -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'msi is dual-purpose and sets default folder for each scope before costing' {
    $root = New-TempFolder
    try {
        New-TestStage $root
        $model = New-MsiTables (New-TestProduct) (Get-StageFiles $root)
        function Get-Table($name) { return @($model.Tables | Where-Object { $_.Name -eq $name })[0] }
        $properties = @{}; foreach ($row in (Get-Table 'Property').Rows) { $properties[$row[0]] = $row[1] }
        Assert-Equal '2' $properties['ALLUSERS'] 'ALLUSERS'
        $folder = @((Get-Table 'Directory').Rows | Where-Object { $_[0] -eq 'INSTALLFOLDER' })[0]
        Assert-Equal @('INSTALLFOLDER', 'TARGETDIR', 'BITOSC~1|Bitoscope') $folder 'INSTALLFOLDER row'
        $actions = @{}; foreach ($row in (Get-Table 'CustomAction').Rows) { $actions[$row[0]] = $row }
        Assert-Equal '[ProgramFiles64Folder]Bitoscope\' $actions['SetInstallFolderPerMachine'][3] 'per-machine folder'
        Assert-Equal '[LocalAppDataFolder]Programs\Bitoscope\' $actions['SetInstallFolderPerUser'][3] 'per-user folder'
        foreach ($sequence in 'InstallUISequence', 'InstallExecuteSequence') {
            $rows = @((Get-Table $sequence).Rows)
            $costing = @($rows | Where-Object { $_[0] -eq 'CostInitialize' })[0][2]
            foreach ($action in 'SetInstallFolderPerMachine', 'SetInstallFolderPerUser') {
                $row = @($rows | Where-Object { $_[0] -eq $action })
                if ($row.Count -ne 1) { throw "$sequence has $($row.Count) rows for $action" }
                if ($row[0][2] -ge $costing) { throw "$action runs at $($row[0][2]) in $sequence, not before CostInitialize ($costing)" }
            }
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

function Get-UiModel {
    $root = New-TempFolder
    try {
        New-TestStage $root
        $model = New-MsiTables (New-TestProduct) (Get-StageFiles $root)
        $tables = @{}; foreach ($table in $model.Tables) { $tables[$table.Name] = $table }
        return $tables
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'msi dialogs: every reference between dialogs, controls, events, actions and sequence exists' {
    $t = Get-UiModel
    foreach ($name in 'Dialog', 'Control', 'ControlEvent', 'RadioButton', 'TextStyle', 'EventMapping') { if (-not $t.ContainsKey($name)) { throw "no $name table" } }
    $dialogs = @{}; foreach ($row in $t['Dialog'].Rows) { $dialogs[$row[0]] = $row }
    foreach ($name in 'ScopeDlg', 'FolderDlg', 'BrowseDlg', 'ProgressDlg', 'ExitDialog', 'FatalError', 'UserExit', 'CancelDlg') { if (-not $dialogs.ContainsKey($name)) { throw "no dialog $name" } }
    $controls = @{}; foreach ($row in $t['Control'].Rows) { $controls["$($row[0])/$($row[1])"] = $row }
    foreach ($dialog in $dialogs.Values) {
        foreach ($index in 7, 8, 9) {
            if ($null -ne $dialog[$index] -and -not $controls.ContainsKey("$($dialog[0])/$($dialog[$index])")) { throw "dialog $($dialog[0]) names missing control $($dialog[$index])" }
        }
        if ($null -eq $dialog[7]) { throw "dialog $($dialog[0]) has no first control" }
    }
    foreach ($control in $controls.Values) {
        if (-not $dialogs.ContainsKey($control[0])) { throw "control $($control[1]) belongs to missing dialog $($control[0])" }
        if ($null -ne $control[10] -and -not $controls.ContainsKey("$($control[0])/$($control[10])")) { throw "control $($control[0])/$($control[1]) has missing next control $($control[10])" }
    }
    $actions = @{}; foreach ($row in $t['CustomAction'].Rows) { $actions[$row[0]] = $row }
    $directories = @{}; foreach ($row in $t['Directory'].Rows) { $directories[$row[0]] = $row }
    foreach ($event in $t['ControlEvent'].Rows) {
        if (-not $controls.ContainsKey("$($event[0])/$($event[1])")) { throw "event on missing control $($event[0])/$($event[1])" }
        if ($event[2] -eq 'SetTargetPath' -and -not ($directories.ContainsKey($event[3]) -or $event[3] -eq '[_BrowseProperty]')) {
            throw "SetTargetPath on $($event[0])/$($event[1]) has argument '$($event[3])': it must be name of directory (INSTALLFOLDER) or [_BrowseProperty], error 2872 otherwise"
        }
        switch ($event[2]) {
            { $_ -in 'NewDialog', 'SpawnDialog' } { if (-not $dialogs.ContainsKey($event[3])) { throw "$($event[2]) of missing dialog $($event[3])" } }
            'DoAction' { if (-not $actions.ContainsKey($event[3])) { throw "DoAction of missing custom action $($event[3])" } }
            'EndDialog' { if ($event[3] -notin 'Return', 'Exit', 'Retry', 'Ignore') { throw "EndDialog with $($event[3])" } }
        }
    }
    foreach ($mapping in $t['EventMapping'].Rows) { if (-not $controls.ContainsKey("$($mapping[0])/$($mapping[1])")) { throw "event mapping on missing control $($mapping[0])/$($mapping[1])" } }
    $styles = @{}; foreach ($row in $t['TextStyle'].Rows) { $styles[$row[0]] = $row }
    foreach ($control in $controls.Values) { foreach ($m in [regex]::Matches([string]$control[9], '\{\\(\w+)\}')) { if (-not $styles.ContainsKey($m.Groups[1].Value)) { throw "control $($control[0])/$($control[1]) uses missing text style $($m.Groups[1].Value)" } } }
    $sequence = @{}; foreach ($row in $t['InstallUISequence'].Rows) { $sequence[$row[0]] = $row[2] }
    foreach ($name in $dialogs.Keys) {
        if ($name -in 'ScopeDlg', 'ProgressDlg', 'ExitDialog', 'FatalError', 'UserExit') { if (-not $sequence.ContainsKey($name)) { throw "dialog $name is not in InstallUISequence" } }
        elseif ($sequence.ContainsKey($name)) { throw "dialog $name must be opened by an event, not by the sequence" }
    }
    if (-not ($sequence['ScopeDlg'] -lt $sequence['ProgressDlg'] -and $sequence['ProgressDlg'] -lt $sequence['ExecuteAction'])) { throw 'order must be ScopeDlg, ProgressDlg, ExecuteAction' }
    Assert-Equal @(-1, -2, -3) @($sequence['ExitDialog'], $sequence['UserExit'], $sequence['FatalError']) 'terminal dialog sequence numbers'
    $property = @{}; foreach ($row in $t['Property'].Rows) { $property[$row[0]] = $row[1] }
    if (-not $styles.ContainsKey($property['DefaultUIFont'])) { throw "DefaultUIFont is $($property['DefaultUIFont'])" }
}

Test-Case 'msi dialogs: scope radio buttons and texts' {
    $t = Get-UiModel
    $group = @($t['Control'].Rows | Where-Object { $_[0] -eq 'ScopeDlg' -and $_[2] -eq 'RadioButtonGroup' })
    Assert-Equal 1 $group.Count 'radio groups on ScopeDlg'
    Assert-Equal 'INSTALLSCOPE' $group[0][8] 'radio group property'
    $radios = @($t['RadioButton'].Rows | Where-Object { $_[0] -eq 'INSTALLSCOPE' } | Sort-Object { $_[1] })
    Assert-Equal @('perUser', 'perMachine') @($radios | ForEach-Object { $_[2] }) 'radio values in order'
    $texts = @($t['Control'].Rows | ForEach-Object { $_[9] }) + @($radios | ForEach-Object { $_[7] })
    foreach ($text in $texts) { if ($null -ne $text -and $text -match '(?i)\b(the|a|an)\b') { throw "text with article: $text" } }
}

Test-Case 'msi dialogs: Next sets scope and default folder, Install checks folder' {
    $t = Get-UiModel
    function Get-Events($dialog, $control) { return , @($t['ControlEvent'].Rows | Where-Object { $_[0] -eq $dialog -and $_[1] -eq $control } | Sort-Object { $_[5] }) }
    function Find-Event($events, $name, $argument, $condition) { return , @($events | Where-Object { $_[2] -eq $name -and $_[3] -eq $argument -and $_[4] -eq $condition }) }
    $next = Get-Events 'ScopeDlg' 'Next'
    foreach ($expected in @(
            @('[ALLUSERS]', '1', 'INSTALLSCOPE="perMachine"'), @('[MSIINSTALLPERUSER]', '{}', 'INSTALLSCOPE="perMachine"'),
            @('[MSIINSTALLPERUSER]', '1', 'INSTALLSCOPE="perUser"'),
            @('DoAction', 'SetInstallFolderPerMachine', 'INSTALLSCOPE="perMachine"'), @('DoAction', 'SetInstallFolderPerUser', 'INSTALLSCOPE="perUser"'),
            @('NewDialog', 'FolderDlg', '1'))) {
        if ((Find-Event $next $expected[0] $expected[1] $expected[2]).Count -ne 1) { throw "ScopeDlg Next lacks $($expected -join ' | ')" }
    }
    $install = Get-Events 'FolderDlg' 'Install'
    $check = Find-Event $install 'SetTargetPath' 'INSTALLFOLDER' '1'; $end = Find-Event $install 'EndDialog' 'Return' '1'
    if ($check.Count -ne 1 -or $end.Count -ne 1 -or $check[0][5] -ge $end[0][5]) { throw 'FolderDlg Install must check folder (SetTargetPath) before it ends dialog' }
    $browse = Get-Events 'FolderDlg' 'Browse'
    if ((Find-Event $browse '[_BrowseProperty]' 'INSTALLFOLDER' '1').Count -ne 1 -or (Find-Event $browse 'SpawnDialog' 'BrowseDlg' '1').Count -ne 1) { throw 'FolderDlg Browse must set _BrowseProperty and open BrowseDlg' }
}

Test-Case 'msi installs per user into user folder without administrator and uninstalls cleanly' {
    Use-PerUserInstall {
        param($root, $product, $shortcut)
        $folder = Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)"
        foreach ($relative in 'bitoscope_gui.exe', 'drivers\demo.exe', 'drivers\sigrok-firmware\fx2lafw-a.fw') {
            if (-not (Test-Path -LiteralPath (Join-Path $folder $relative))) { throw "per-user install has no $relative in $folder" }
        }
        Assert-Equal 1 @(Find-UserUninstallEntry $product.Name).Count 'uninstall entries of current user'
        if (-not (Test-Path -LiteralPath $shortcut)) { throw "no Start menu entry $shortcut" }
    }
    if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\BitoscopeTest*')) { throw 'test left a folder in Programs' }
}

Test-Case 'two products with same files install side by side per user and uninstall independently' {
    $root = New-TempFolder
    $first = New-UniqueTestProduct
    $second = New-UniqueTestProduct
    $folders = @{}; foreach ($product in $first, $second) { $folders[$product.Name] = Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)" }
    try {
        New-TestStage (Join-Path $root 'stage')
        foreach ($item in @(@($first, 'first.msi'), @($second, 'second.msi'))) {
            New-MsiPackage -Stage (Join-Path $root 'stage') -OutputPath (Join-Path $root $item[1]) -WorkFolder (Join-Path $root "work-$($item[1])") -Product $item[0]
            Assert-Equal 0 (Invoke-TestMsiexec @('/i', (Join-Path $root $item[1]), '/qn', 'MSIINSTALLPERUSER=1')) "install of $($item[1])"
        }
        foreach ($product in $first, $second) {
            foreach ($relative in 'bitoscope_gui.exe', 'drivers\demo.exe', 'drivers\sigrok-firmware\fx2lafw-a.fw') {
                if (-not (Test-Path -LiteralPath (Join-Path $folders[$product.Name] $relative))) { throw "$($product.Name) has no $relative" }
            }
        }
        foreach ($product in $first, $second) { if (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$($product.Name).lnk"))) { throw "no Start menu entry of $($product.Name)" } }
        Assert-Equal 0 (Invoke-TestMsiexec @('/x', (Join-Path $root 'first.msi'), '/qn')) 'uninstall of first'
        if (Test-Path -LiteralPath (Join-Path $folders[$first.Name] 'bitoscope_gui.exe')) { throw 'first product still has files after its uninstall' }
        foreach ($relative in 'bitoscope_gui.exe', 'drivers\demo.exe') {
            if (-not (Test-Path -LiteralPath (Join-Path $folders[$second.Name] $relative))) { throw "uninstall of first removed $relative of second" }
        }
        if (Test-Path -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$($first.Name).lnk")) { throw 'uninstall of first left its Start menu entry' }
        if (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$($second.Name).lnk"))) { throw 'uninstall of first removed Start menu entry of second' }
        Assert-Equal 0 (Invoke-TestMsiexec @('/x', (Join-Path $root 'second.msi'), '/qn')) 'uninstall of second'
        if (Test-Path -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$($second.Name).lnk")) { throw 'uninstall of second left its Start menu entry' }
    } finally {
        foreach ($product in $first, $second) {
            [void](Invoke-TestMsiexec @('/x', $product.ProductCode, '/qn'))
            Remove-Item -LiteralPath $folders[$product.Name] -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$($product.Name).lnk") -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'INSTALLFOLDER on the command line decides the folder' {
    $target = Join-Path (New-TempFolder) 'chosen folder'
    try {
        Use-PerUserInstall {
            param($root, $product, $shortcut)
            if (-not (Test-Path -LiteralPath (Join-Path $target 'bitoscope_gui.exe'))) { throw "no bitoscope_gui.exe in $target" }
            if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)")) { throw 'default folder was used as well' }
        } @("INSTALLFOLDER=$target\")
        if (@(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) { throw "uninstall left files in $target" }
    } finally { Remove-Item -LiteralPath (Split-Path -Parent $target) -Recurse -Force -ErrorAction SilentlyContinue }
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

Test-Case 'step does not wait for process its program leaves behind' {
    $root = New-TempFolder
    $marker = 'bitoscope-dist-leftover-' + [guid]::NewGuid().ToString('N')
    try {
        $inner = "Start-Sleep -Seconds 20; '$marker'"
        $outer = "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-Command',`"$inner`""
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Step 'Leave process behind' 'powershell.exe' @('-NoProfile', '-Command', $outer) -Logs $root
        $seconds = $watch.Elapsed.TotalSeconds
        if ($seconds -gt 10) { throw "step took $($seconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)) s: it waited for leftover process" }
    } finally {
        Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $marker } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FlakyStep([int]$FailTimes, [hashtable]$Options) {
    $root = New-TempFolder
    try {
        $script = Join-Path $root 'flaky.ps1'
        [System.IO.File]::WriteAllText($script, 'param($Counter, $FailTimes) $n = 1; if (Test-Path $Counter) { $n = [int](Get-Content $Counter) + 1 }; Set-Content $Counter $n; if ($n -le [int]$FailTimes) { exit 1 }')
        $counter = Join-Path $root 'count.txt'
        $error = $null
        try { Invoke-Step 'Flaky' 'powershell.exe' @('-NoProfile', '-File', $script, $counter, "$FailTimes") -Logs $root @Options } catch { $error = "$_" }
        return [pscustomobject]@{ Runs = [string](Get-Content $counter); Error = $error }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'step is repeated until it works' {
    $result = Invoke-FlakyStep 2 @{ Attempts = 3; RetrySeconds = 0 }
    Assert-Equal @('3', '') @($result.Runs, [string]$result.Error)
}

Test-Case 'step gives up after last attempt and by default runs once' {
    $result = Invoke-FlakyStep 5 @{ Attempts = 3; RetrySeconds = 0 }
    Assert-Equal '3' $result.Runs 'runs with 3 attempts'
    if ($result.Error -notmatch 'Flaky failed \(exit 1\) after 3 attempts') { throw "message: $($result.Error)" }
    $once = Invoke-FlakyStep 1 @{}
    Assert-Equal '1' $once.Runs 'runs by default'
    if ($once.Error -notmatch 'Flaky failed \(exit 1\); full output in') { throw "message: $($once.Error)" }
}

function New-FirmwareFolder([string]$Folder, [string]$Text) {
    New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Folder 'fx2lafw-a.fw'), $Text)
    [System.IO.File]::WriteAllText((Join-Path $Folder 'COPYING'), 'licence')
}

function Read-Firmware([string]$Folder) { return [System.IO.File]::ReadAllText((Join-Path $Folder 'fx2lafw-a.fw')) }

Test-Case 'downloaded firmware is kept in cache' {
    $root = New-TempFolder
    try {
        $target = "$root\bridge\third_party\sigrok-firmware"; $cache = "$root\cache"
        New-FirmwareFolder $target 'new'
        Assert-Equal 'saved' (Save-FirmwareForCache $target $cache)
        Assert-Equal 'new' (Read-Firmware $cache)
        Assert-Equal 'licence' ([System.IO.File]::ReadAllText("$cache\COPYING"))
        Assert-Equal 'no cache' (Save-FirmwareForCache $target '')
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'cached firmware replaces nothing without files and fills missing firmware' {
    $root = New-TempFolder
    try {
        $target = "$root\bridge\third_party\sigrok-firmware"; $cache = "$root\cache"
        Assert-Equal $false (Use-CachedFirmware $cache $target) 'cache folder missing'
        Assert-Equal $false (Use-CachedFirmware '' $target) 'no cache folder named'
        New-Item -ItemType Directory $cache | Out-Null; [System.IO.File]::WriteAllText("$cache\README", 'no firmware')
        Assert-Equal $false (Use-CachedFirmware $cache $target) 'cache without .fw'
        New-FirmwareFolder $cache 'cached'
        Assert-Equal $true (Use-CachedFirmware $cache $target) 'cache with firmware'
        Assert-Equal 'cached' (Read-Firmware $target)
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'newer download replaces older cache completely' {
    $root = New-TempFolder
    try {
        $target = "$root\t"; $cache = "$root\cache"
        New-FirmwareFolder $cache 'old'; [System.IO.File]::WriteAllText("$cache\leftover.fw", 'gone')
        New-FirmwareFolder $target 'new'
        [void](Save-FirmwareForCache $target $cache)
        Assert-Equal 'new' (Read-Firmware $cache)
        Assert-Equal $false (Test-Path "$cache\leftover.fw") 'leftover firmware file'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case 'SED quiet commands: standard user per user, administrator per machine only when elevated' {
    $text = ConvertTo-SedText 'C:\o\a.msi' 'C:\o\a.exe' 'A'
    if ($text -notmatch '(?m)^UserQuietInstCmd=msiexec\.exe /i a\.msi /qn MSIINSTALLPERUSER=1\r?$') { throw "UserQuietInstCmd line wrong:`n$text" }
    $admin = 'AdminQuietInstCmd=cmd /c fltmc >nul 2>&1 & if errorlevel 1 (msiexec.exe /i a.msi /qn MSIINSTALLPERUSER=1) else msiexec.exe /i a.msi /qn'
    if ($text -notmatch ('(?m)^' + [regex]::Escape($admin) + '\r?$')) { throw "AdminQuietInstCmd line wrong:`n$text" }
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

Test-Case 'imports reader works in script started as .\script from another command' {
    $root = New-TempFolder
    try {
        $dist = Join-Path $PSScriptRoot 'dist.ps1'
        $script = @"
[CmdletBinding()]
param()
`$ErrorActionPreference = 'Stop'
. '$($dist.Replace("'", "''"))'
function Invoke-Reader {
    `$reader = New-ImportsReader (Get-VisualStudio).Dumpbin
    `$names = foreach (`$name in (& `$reader "`$env:SystemRoot\System32\cmd.exe")) { `$name }
    `$names -join ','
}
Invoke-Reader
"@
        [System.IO.File]::WriteAllText((Join-Path $root 'reader.ps1'), $script)
        Push-Location $root
        try { $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '.\reader.ps1' 2>&1 } finally { Pop-Location }
        if (($output -join ' ') -notmatch '(?i)^[\w.-]+\.dll(,[\w.-]+\.dll)+$') { throw "imports of cmd.exe through reader: $($output -join ' ')" }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
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

Test-Case 'clean distribution has no problems, broken one names each' {
    $root = New-TempFolder
    try {
        New-Item -ItemType Directory -Path "$root\stage\drivers", "$root\system" | Out-Null
        [System.IO.File]::WriteAllText("$root\stage\bitoscope_gui.exe", 'gui')
        [System.IO.File]::WriteAllText("$root\stage\drivers\demo.exe", 'demo')
        [System.IO.File]::WriteAllText("$root\system\kernel32.dll", '')
        $clean = { param($path) @('KERNEL32.dll') }
        Assert-Equal 0 (Get-DistributionProblems "$root\stage" "$root\system" $clean).Count 'problems of clean distribution'
        $broken = { param($path) if ($path -like '*demo.exe') { @('gone.dll') } else { @('KERNEL32.dll') } }
        [System.IO.File]::WriteAllText("$root\stage\bitoscope_cli.exe", 'cli')
        Assert-Equal @('drivers\demo.exe needs gone.dll, found nowhere it would be loaded from', 'bitoscope_cli.exe is in distribution') `
            (Get-DistributionProblems "$root\stage" "$root\system" $broken) 'problems of broken distribution'
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
