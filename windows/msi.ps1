# SPDX-License-Identifier: MIT

Set-StrictMode -Version 3

. (Join-Path $PSScriptRoot 'msi-ui.ps1')

if (-not ('BitoscopeDist.MsiNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace BitoscopeDist {
public static class MsiNative {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiOpenDatabaseW(string path, IntPtr persist, out uint database);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiDatabaseImportW(uint database, string folder, string file);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiDatabaseOpenViewW(uint database, string query, out uint view);
    [DllImport("msi.dll")]
    public static extern uint MsiViewExecute(uint view, uint record);
    [DllImport("msi.dll")]
    public static extern uint MsiViewFetch(uint view, out uint record);
    [DllImport("msi.dll")]
    public static extern uint MsiViewModify(uint view, int mode, uint record);
    [DllImport("msi.dll")]
    public static extern uint MsiViewClose(uint view);
    [DllImport("msi.dll")]
    public static extern uint MsiCreateRecord(uint fields);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiRecordSetStringW(uint record, uint field, string value);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiRecordSetStreamW(uint record, uint field, string path);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiRecordGetStringW(uint record, uint field, StringBuilder value, ref uint length);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiGetSummaryInformationW(uint database, string path, uint updates, out uint summary);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiSummaryInfoSetPropertyW(uint summary, uint property, uint type, int number,
                                                         IntPtr time, string text);
    [DllImport("msi.dll")]
    public static extern uint MsiSummaryInfoPersist(uint summary);
    [DllImport("msi.dll")]
    public static extern uint MsiDatabaseCommit(uint database);
    [DllImport("msi.dll")]
    public static extern uint MsiCloseHandle(uint handle);
    [DllImport("msi.dll")]
    public static extern uint MsiGetLastErrorRecord();
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiFormatRecordW(uint install, uint record, StringBuilder text, ref uint length);

    public static string LastError() {
        uint record = MsiGetLastErrorRecord();
        if (record == 0) return "no details";
        uint length = 1024;
        var text = new StringBuilder((int)length);
        MsiFormatRecordW(0, record, text, ref length);
        MsiCloseHandle(record);
        return text.ToString();
    }

    public static string GetString(uint record, uint field) {
        uint length = 1024;
        var text = new StringBuilder((int)length);
        MsiRecordGetStringW(record, field, text, ref length);
        return text.ToString();
    }
}
}
'@
}

$script:MsiOpenCreate = [IntPtr]3
$script:MsiOpenReadOnly = [IntPtr]0
$script:MsiModifyInsert = 1
$script:ShortNameCharacters = "A-Za-z0-9_\-!#$%&'()@^``{}~"

function ConvertTo-MsiexecArguments([string[]]$Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '^([A-Za-z_][A-Za-z0-9_.]*)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].TrimEnd('\')
            if ($value -eq '' -or $value -match '[\s"]') { "$name=`"$value`"" } else { "$name=$value" }
        } elseif ($argument -match '[\s"]') {
            "`"$argument`""
        } else {
            $argument
        }
    }
    return $quoted -join ' '
}

function Assert-MsiCall([uint32]$Result, [string]$What) {
    if ($Result -ne 0) {
        throw "Windows Installer: $What failed with error $Result ($([BitoscopeDist.MsiNative]::LastError()))"
    }
}

function Test-ShortName([string]$Name) {
    $c = $script:ShortNameCharacters
    return $Name -match "^[$c]{1,8}(\.[$c]{1,3})?$"
}

function Get-MsiFileName([string]$LongName, [System.Collections.Generic.HashSet[string]]$Taken) {
    if ((Test-ShortName $LongName) -and $Taken.Add($LongName)) {
        return $LongName
    }
    $dot = $LongName.LastIndexOf('.')
    if ($dot -gt 0) {
        $stem = $LongName.Substring(0, $dot)
        $extension = $LongName.Substring($dot + 1)
    } else {
        $stem = $LongName
        $extension = ''
    }
    $pattern = "[^$($script:ShortNameCharacters)]"
    $stem = ($stem -replace $pattern, '').ToUpperInvariant()
    $extension = ($extension -replace $pattern, '').ToUpperInvariant()
    if ($stem -eq '') { $stem = '_' }
    if ($extension.Length -gt 3) { $extension = $extension.Substring(0, 3) }
    for ($number = 1; $number -lt 100000; $number++) {
        $suffix = "~$number"
        $keep = [Math]::Min($stem.Length, 8 - $suffix.Length)
        $short = $stem.Substring(0, $keep) + $suffix
        if ($extension -ne '') { $short += ".$extension" }
        if ($Taken.Add($short)) {
            return "$short|$LongName"
        }
    }
    throw "no free short name for $LongName"
}

function Get-StableHex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))
    } finally {
        $sha.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-StableGuid([string]$Text) {
    $hex = (Get-StableHex "bitoscope-dist component $Text").Substring(0, 32).ToUpperInvariant()
    return '{' + $hex.Substring(0, 8) + '-' + $hex.Substring(8, 4) + '-' + $hex.Substring(12, 4) + '-' +
        $hex.Substring(16, 4) + '-' + $hex.Substring(20, 12) + '}'
}

function New-MsiTable([string]$Name, [string[]]$Columns, [string[]]$Types, [string[]]$Keys) {
    return [pscustomobject]@{
        Name = $Name
        Columns = $Columns
        Types = $Types
        Keys = $Keys
        Rows = [System.Collections.Generic.List[object[]]]::new()
    }
}

function Add-MsiRow($Table, [object[]]$Values) {
    if ($Values.Count -ne $Table.Columns.Count) {
        throw "table $($Table.Name) has $($Table.Columns.Count) columns, row has $($Values.Count)"
    }
    $Table.Rows.Add($Values)
}

function ConvertTo-IdtText($Table) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Table.Columns -join "`t")
    $lines.Add($Table.Types -join "`t")
    $lines.Add((@($Table.Name) + $Table.Keys) -join "`t")
    foreach ($row in $Table.Rows) {
        $cells = foreach ($value in $row) {
            if ($null -eq $value) { '' } else {
                $text = [string]$value
                if ($text -match "[`t`r`n]") { throw "table $($Table.Name): value with tab or line break: $text" }
                $text
            }
        }
        $lines.Add($cells -join "`t")
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Get-StageFiles([string]$Stage) {
    $root = (Resolve-Path -LiteralPath $Stage).Path.TrimEnd('\')
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
        [pscustomobject]@{
            Path = $_.FullName
            Relative = $_.FullName.Substring($root.Length + 1)
            Size = $_.Length
        }
    }
    return @($files | Sort-Object { $_.Relative.ToLowerInvariant() })
}

function Get-ProductFeatures($Product) {
    $property = $Product.PSObject.Properties['Features']
    if ($null -eq $property) { return @() }
    return @($property.Value)
}

function New-MsiTables($Product, [object[]]$Files, [hashtable]$FileFeatures = @{}) {
    $driverFeatures = @(Get-ProductFeatures $Product)
    $knownFeatures = @('Main') + @($driverFeatures | ForEach-Object { $_.Id })
    $directory = New-MsiTable 'Directory' @('Directory', 'Directory_Parent', 'DefaultDir') @('s72', 'S72', 'l255') @('Directory')
    $component = New-MsiTable 'Component' @('Component', 'ComponentId', 'Directory_', 'Attributes', 'Condition', 'KeyPath') `
        @('s72', 'S38', 's72', 'i2', 'S255', 'S72') @('Component')
    $file = New-MsiTable 'File' @('File', 'Component_', 'FileName', 'FileSize', 'Version', 'Language', 'Attributes', 'Sequence') `
        @('s72', 's72', 'l255', 'i4', 'S72', 'S20', 'I2', 'i2') @('File')
    $feature = New-MsiTable 'Feature' @('Feature', 'Feature_Parent', 'Title', 'Description', 'Display', 'Level', 'Directory_', 'Attributes') `
        @('s38', 'S38', 'L64', 'L255', 'I2', 'i2', 'S72', 'i2') @('Feature')
    $featureComponents = New-MsiTable 'FeatureComponents' @('Feature_', 'Component_') @('s38', 's72') @('Feature_', 'Component_')
    $media = New-MsiTable 'Media' @('DiskId', 'LastSequence', 'DiskPrompt', 'Cabinet', 'VolumeLabel', 'Source') `
        @('i2', 'i2', 'L64', 'S255', 'S32', 'S72') @('DiskId')
    $property = New-MsiTable 'Property' @('Property', 'Value') @('s72', 'l0') @('Property')
    $upgrade = New-MsiTable 'Upgrade' @('UpgradeCode', 'VersionMin', 'VersionMax', 'Language', 'Attributes', 'Remove', 'ActionProperty') `
        @('s38', 'S20', 'S20', 'S255', 'i4', 'S255', 's72') @('UpgradeCode', 'VersionMin', 'VersionMax', 'Language', 'Attributes')
    $featureCondition = New-MsiTable 'Condition' @('Feature_', 'Level', 'Condition') @('s38', 'i2', 'S255') @('Feature_', 'Level')
    $launch = New-MsiTable 'LaunchCondition' @('Condition', 'Description') @('s255', 'l255') @('Condition')
    $shortcut = New-MsiTable 'Shortcut' @('Shortcut', 'Directory_', 'Name', 'Component_', 'Target', 'Arguments', 'Description',
        'Hotkey', 'Icon_', 'IconIndex', 'ShowCmd', 'WkDir') `
        @('s72', 's72', 'l128', 's72', 's72', 'S255', 'L255', 'I2', 'S72', 'I2', 'I2', 'S72') @('Shortcut')

    $customAction = New-MsiTable 'CustomAction' @('Action', 'Type', 'Source', 'Target', 'ExtendedType') `
        @('s72', 'i2', 'S72', 'S255', 'I4') @('Action')
    Add-MsiRow $directory @('TARGETDIR', $null, 'SourceDir')
    Add-MsiRow $directory @('ProgramMenuFolder', 'TARGETDIR', '.')
    $topNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Add-MsiRow $directory @('INSTALLFOLDER', 'TARGETDIR', (Get-MsiFileName $Product.Folder $topNames))
    Add-MsiRow $customAction @('SetInstallFolderPerMachine', 51, 'INSTALLFOLDER', "[ProgramFiles64Folder]$($Product.Folder)\", $null)
    Add-MsiRow $customAction @('SetInstallFolderPerUser', 51, 'INSTALLFOLDER', "[LocalAppDataFolder]Programs\$($Product.Folder)\", $null)
    $perMachine = 'ALLUSERS=1 OR (ALLUSERS=2 AND Privileged AND NOT MSIINSTALLPERUSER)'

    $directoryIds = @{ '' = 'INSTALLFOLDER' }
    $namesIn = @{}
    function Get-NamesIn([string]$Id) {
        if (-not $namesIn.ContainsKey($Id)) {
            $namesIn[$Id] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        }
        return , $namesIn[$Id]
    }
    function Get-DirectoryId([string]$Relative) {
        if ($directoryIds.ContainsKey($Relative)) { return $directoryIds[$Relative] }
        $slash = $Relative.LastIndexOf('\')
        $parentRelative = if ($slash -lt 0) { '' } else { $Relative.Substring(0, $slash) }
        $leaf = $Relative.Substring($slash + 1)
        $parent = Get-DirectoryId $parentRelative
        $id = 'd' + (Get-StableHex "dir $Relative").Substring(0, 24)
        Add-MsiRow $directory @($id, $parent, (Get-MsiFileName $leaf (Get-NamesIn $parent)))
        $directoryIds[$Relative] = $id
        return $id
    }

    $sequence = 0
    $guiKey = $null
    $cabinetOrder = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Files) {
        $sequence++
        $slash = $entry.Relative.LastIndexOf('\')
        $folder = if ($slash -lt 0) { '' } else { $entry.Relative.Substring(0, $slash) }
        $leaf = $entry.Relative.Substring($slash + 1)
        $directoryId = Get-DirectoryId $folder
        $hex = (Get-StableHex "file $($entry.Relative)").Substring(0, 24)
        $fileKey = "f$hex"
        $componentKey = "c$hex"
        Add-MsiRow $component @($componentKey, (Get-StableGuid "$($Product.UpgradeCode) $($entry.Relative)"), $directoryId, 256, $null, $fileKey)
        Add-MsiRow $file @($fileKey, $componentKey, (Get-MsiFileName $leaf (Get-NamesIn $directoryId)), $entry.Size,
            $null, $null, $null, $sequence)
        $featuresOfFile = if ($FileFeatures.ContainsKey($entry.Relative.ToLowerInvariant())) { @($FileFeatures[$entry.Relative.ToLowerInvariant()]) } else { @('Main') }
        foreach ($featureId in $featuresOfFile) {
            if ($featureId -notin $knownFeatures) { throw "$($entry.Relative) names feature '$featureId', which the product does not have" }
            Add-MsiRow $featureComponents @($featureId, $componentKey)
        }
        $cabinetOrder.Add([pscustomobject]@{ Key = $fileKey; Path = $entry.Path })
        if ($entry.Relative -eq $Product.Program) {
            $guiKey = $fileKey
            $guiComponent = $componentKey
        }
    }
    if ($null -eq $guiKey) { throw "stage holds no $($Product.Program)" }

    Add-MsiRow $feature @('Main', $null, $Product.Name, $Product.Name, 1, 1, 'INSTALLFOLDER', 0)
    foreach ($driver in $driverFeatures) {
        Add-MsiRow $feature @($driver.Id, 'Main', $driver.Title, $driver.Title, 0, 1, $null, 0)
        Add-MsiRow $featureCondition @($driver.Id, 0, "NOT $($driver.Property)")
    }
    Add-MsiRow $media @(1, $sequence, $null, "#$($Product.Cabinet)", $null, $null)
    $menuNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Add-MsiRow $shortcut @('ProgramShortcut', 'ProgramMenuFolder', (Get-MsiFileName $Product.Name $menuNames), $guiComponent,
        "[#$guiKey]", $null, $Product.Name, $null, $null, $null, $null, 'INSTALLFOLDER')

    foreach ($pair in @(
            @('ProductCode', $Product.ProductCode),
            @('ProductName', $Product.Name),
            @('ProductVersion', $Product.Version),
            @('ProductLanguage', '1033'),
            @('Manufacturer', $Product.Manufacturer),
            @('UpgradeCode', $Product.UpgradeCode),
            @('ALLUSERS', '2'),
            @('ARPNOMODIFY', '1'),
            @('ARPURLINFOABOUT', $Product.Url),
            @('SecureCustomProperties', (@('UPGRADEFOUND', 'NEWERFOUND') + @($driverFeatures | ForEach-Object { $_.Property }) -join ';')))) {
        Add-MsiRow $property $pair
    }
    foreach ($driver in $driverFeatures) { Add-MsiRow $property @($driver.Property, '1') }
    Add-MsiRow $upgrade @($Product.UpgradeCode, $null, $Product.Version, $null, 513, $null, 'UPGRADEFOUND')
    Add-MsiRow $upgrade @($Product.UpgradeCode, $Product.Version, $null, $null, 2, $null, 'NEWERFOUND')
    Add-MsiRow $launch @('NOT NEWERFOUND', "Newer $($Product.Name) is already installed.")

    $ui = New-MsiUiTables $Product $perMachine $driverFeatures
    foreach ($pair in $ui.Properties) { Add-MsiRow $property $pair }
    foreach ($row in $ui.CustomActions) { Add-MsiRow $customAction $row }
    $folderActions = @(
        @('SetInstallFolderPerMachine', 700, "NOT INSTALLFOLDER AND ($perMachine)"),
        @('SetInstallFolderPerUser', 710, "NOT INSTALLFOLDER AND NOT ($perMachine)"))
    $sequences = @{
        InstallExecuteSequence = $folderActions + @(
            @('FindRelatedProducts', 25), @('LaunchConditions', 100), @('CostInitialize', 800), @('FileCost', 900),
            @('CostFinalize', 1000), @('MigrateFeatureStates', 1200), @('InstallValidate', 1400),
            @('RemoveExistingProducts', 1401), @('InstallInitialize', 1500), @('ProcessComponents', 1600),
            @('UnpublishFeatures', 1800), @('RemoveShortcuts', 3200), @('RemoveFiles', 3500), @('InstallFiles', 4000),
            @('CreateShortcuts', 4500), @('RegisterUser', 6000), @('RegisterProduct', 6100), @('PublishFeatures', 6300),
            @('PublishProduct', 6400), @('InstallFinalize', 6600))
        InstallUISequence = $folderActions + $ui.Sequence + @(
            @('FindRelatedProducts', 25), @('LaunchConditions', 100), @('CostInitialize', 800), @('FileCost', 900),
            @('CostFinalize', 1000), @('MigrateFeatureStates', 1200), @('ExecuteAction', 1300))
        AdminExecuteSequence = @(
            @('CostInitialize', 800), @('FileCost', 900), @('CostFinalize', 1000), @('InstallValidate', 1400),
            @('InstallInitialize', 1500), @('InstallAdminPackage', 3900), @('InstallFiles', 4000),
            @('InstallFinalize', 6600))
        AdminUISequence = @(
            @('CostInitialize', 800), @('FileCost', 900), @('CostFinalize', 1000), @('ExecuteAction', 1300))
    }
    $tables = @($directory, $component, $file, $feature, $featureCondition, $featureComponents, $media, $property, $upgrade, $launch, $shortcut, $customAction) + $ui.Tables
    foreach ($name in $sequences.Keys) {
        $table = New-MsiTable $name @('Action', 'Condition', 'Sequence') @('s72', 'S255', 'I2') @('Action')
        foreach ($action in $sequences[$name]) {
            Add-MsiRow $table @($action[0], $(if ($action.Count -gt 2) { $action[2] } else { $null }), $action[1])
        }
        $tables += $table
    }
    return [pscustomobject]@{ Tables = $tables; Cabinet = $cabinetOrder }
}

function New-Cabinet([object[]]$Entries, [string]$CabinetPath, [string]$WorkFolder) {
    $folder = Split-Path -Parent $CabinetPath
    $directives = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
            '.OPTION EXPLICIT',
            ".Set CabinetNameTemplate=$(Split-Path -Leaf $CabinetPath)",
            ".Set DiskDirectoryTemplate=`"$folder`"",
            '.Set Cabinet=on', '.Set Compress=on', '.Set CompressionType=LZX', '.Set CompressionMemory=21',
            '.Set MaxDiskSize=0', '.Set CabinetFileCountThreshold=0', '.Set FolderFileCountThreshold=0',
            '.Set FolderSizeThreshold=0', '.Set MaxCabinetSize=0', '.Set UniqueFiles=on',
            '.Set InfFileName=NUL', '.Set RptFileName=NUL')) {
        $directives.Add($line)
    }
    foreach ($entry in $Entries) {
        if ($entry.Path.Contains('"')) { throw "file name with quote: $($entry.Path)" }
        $directives.Add("`"$($entry.Path)`" $($entry.Key)")
    }
    $ddf = Join-Path $WorkFolder 'cabinet.ddf'
    [System.IO.File]::WriteAllLines($ddf, $directives, [System.Text.Encoding]::ASCII)
    $output = & "$env:SystemRoot\System32\makecab.exe" /F $ddf 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $CabinetPath)) {
        throw "makecab failed (exit $LASTEXITCODE):`n$($output -join "`n")"
    }
}

function Set-SummaryInformation([uint32]$Database, $Product) {
    $summary = [uint32]0
    Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiGetSummaryInformationW($Database, $null, 20, [ref]$summary)) 'opening summary information'
    try {
        $typeShort = 2
        $typeLong = 3
        $typeText = 30
        $values = @(
            @(1, $typeShort, 1252, $null),
            @(2, $typeText, 0, 'Installation Database'),
            @(3, $typeText, 0, $Product.Name),
            @(4, $typeText, 0, $Product.Manufacturer),
            @(5, $typeText, 0, 'Installer'),
            @(7, $typeText, 0, 'x64;1033'),
            @(9, $typeText, 0, $Product.PackageCode),
            @(14, $typeLong, 500, $null),
            @(15, $typeLong, 2, $null),
            @(18, $typeText, 0, 'bitoscope-dist'),
            @(19, $typeLong, 2, $null))
        foreach ($value in $values) {
            Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiSummaryInfoSetPropertyW($summary, $value[0], $value[1], $value[2],
                    [IntPtr]::Zero, $value[3])) "setting summary property $($value[0])"
        }
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiSummaryInfoPersist($summary)) 'saving summary information'
    } finally {
        [void][BitoscopeDist.MsiNative]::MsiCloseHandle($summary)
    }
}

function Add-MsiStream([uint32]$Database, [string]$Name, [string]$Path) {
    $view = [uint32]0
    Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiDatabaseOpenViewW($Database, 'SELECT `Name`, `Data` FROM `_Streams`', [ref]$view)) 'opening _Streams'
    $record = [BitoscopeDist.MsiNative]::MsiCreateRecord(2)
    try {
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiViewExecute($view, 0)) 'reading _Streams'
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiRecordSetStringW($record, 1, $Name)) 'naming stream'
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiRecordSetStreamW($record, 2, $Path)) "reading $Path"
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiViewModify($view, $script:MsiModifyInsert, $record)) "adding stream $Name"
    } finally {
        [void][BitoscopeDist.MsiNative]::MsiCloseHandle($record)
        [void][BitoscopeDist.MsiNative]::MsiViewClose($view)
        [void][BitoscopeDist.MsiNative]::MsiCloseHandle($view)
    }
}

function New-MsiPackage {
    param(
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$WorkFolder,
        [Parameter(Mandatory)] $Product,
        [hashtable]$FileFeatures = @{}
    )
    if (Test-Path -LiteralPath $WorkFolder) { Remove-Item -LiteralPath $WorkFolder -Recurse -Force }
    $idtFolder = Join-Path $WorkFolder 'idt'
    New-Item -ItemType Directory -Force -Path $idtFolder | Out-Null
    $model = New-MsiTables $Product (Get-StageFiles $Stage) $FileFeatures
    foreach ($table in $model.Tables) {
        [System.IO.File]::WriteAllText((Join-Path $idtFolder "$($table.Name).idt"), (ConvertTo-IdtText $table),
            [System.Text.Encoding]::ASCII)
    }
    $cabinet = Join-Path $WorkFolder $Product.Cabinet
    New-Cabinet $model.Cabinet $cabinet $WorkFolder

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    $partial = "$OutputPath.part"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $database = [uint32]0
    Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiOpenDatabaseW($partial, $script:MsiOpenCreate, [ref]$database)) "creating $partial"
    try {
        foreach ($table in $model.Tables) {
            Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiDatabaseImportW($database, $idtFolder, "$($table.Name).idt")) "importing $($table.Name)"
        }
        Add-MsiStream $database $Product.Cabinet $cabinet
        Set-SummaryInformation $database $Product
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiDatabaseCommit($database)) 'saving database'
    } finally {
        [void][BitoscopeDist.MsiNative]::MsiCloseHandle($database)
    }
    Move-Item -LiteralPath $partial -Destination $OutputPath
}

function Invoke-MsiQuery([string]$Package, [string]$Query) {
    $database = [uint32]0
    Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiOpenDatabaseW($Package, $script:MsiOpenReadOnly, [ref]$database)) "opening $Package"
    $view = [uint32]0
    try {
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiDatabaseOpenViewW($database, $Query, [ref]$view)) "query $Query"
        Assert-MsiCall ([BitoscopeDist.MsiNative]::MsiViewExecute($view, 0)) "query $Query"
        $rows = [System.Collections.Generic.List[string]]::new()
        while ($true) {
            $record = [uint32]0
            if ([BitoscopeDist.MsiNative]::MsiViewFetch($view, [ref]$record) -ne 0) { break }
            $rows.Add([BitoscopeDist.MsiNative]::GetString($record, 1))
            [void][BitoscopeDist.MsiNative]::MsiCloseHandle($record)
        }
        return , $rows.ToArray()
    } finally {
        if ($view -ne 0) {
            [void][BitoscopeDist.MsiNative]::MsiViewClose($view)
            [void][BitoscopeDist.MsiNative]::MsiCloseHandle($view)
        }
        [void][BitoscopeDist.MsiNative]::MsiCloseHandle($database)
    }
}
