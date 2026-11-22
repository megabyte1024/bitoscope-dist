# SPDX-License-Identifier: MIT

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'dist.ps1')
. (Join-Path $PSScriptRoot 'msi.ps1')
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Count = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:Count++
    try {
        & $Body
        Write-Host "ok    $Name"
    } catch {
        $where = "line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
        $script:Failures.Add("$Name : $_ ($where)")
        Write-Host "FAIL  $Name : $_ ($where)"
    }
}

function Assert-Equal($Expected, $Actual, [string]$What = 'value') {
    if ("$Expected" -cne "$Actual") { throw "$What expected [$Expected], got [$Actual]" }
}

function New-TempFolder {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("bitoscope-dist-uitest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Get-InstallerControls([int]$ProcessId, [string]$Type) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId))
    $controlType = [System.Windows.Automation.ControlType]::($Type)
    $found = foreach ($window in $windows) {
        try {
            $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $controlType))
        } catch { }
    }
    return @($found | Where-Object { $null -ne $_ })
}

function Get-ControlName($Element) {
    try { return [string]$Element.Current.Name } catch { return $null }
}

function Get-Control([int]$ProcessId, [string]$Type, [string]$Name) {
    foreach ($element in (Get-InstallerControls $ProcessId $Type)) {
        $text = Get-ControlName $element
        if ($null -ne $text -and (($Name -eq '') -or ($text.Replace('&', '') -eq $Name))) { return $element }
    }
    return $null
}

function Show-InstallerControls([int]$ProcessId) {
    $names = foreach ($type in 'Button', 'RadioButton', 'CheckBox', 'Edit', 'Text') {
        foreach ($element in (Get-InstallerControls $ProcessId $type)) { "$type '$(Get-ControlName $element)'" }
    }
    return ($names -join '; ')
}

function Wait-Control([System.Diagnostics.Process]$Process, [string]$Type, [string]$Name, [int]$Seconds = 60) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $until) {
        $element = Get-Control $Process.Id $Type $Name
        if ($null -ne $element) { return $element }
        if ($Process.HasExited) { throw "installer ended (exit $($Process.ExitCode)) before $Type '$Name' appeared" }
        Start-Sleep -Milliseconds 300
    }
    throw "no $Type '$Name' after $Seconds s; installer shows: $(Show-InstallerControls $Process.Id)"
}

function Invoke-Control($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-Control($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}

function Get-ToggleState($Element) {
    return [string]$Element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
}

function Switch-Control($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
}

function Get-ControlValue($Element) {
    return $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}

function Set-ControlValue($Element, [string]$Text) {
    $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Text)
}

function Start-Setup([string]$Msi, [string]$Log) {
    return Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList (ConvertTo-MsiexecArguments @('/i', $Msi, '/l*v', $Log)) -PassThru
}

function New-UiTestProduct {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return [pscustomobject]@{
        Name = "Bitoscope UiTest $id"; Folder = "BitoscopeUiTest$id"; Version = '1.0.0'; Manufacturer = 'Test'
        UpgradeCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        ProductCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        PackageCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        Url = 'https://example.invalid'; Program = 'bitoscope_gui.exe'; Cabinet = 'bitoscope.cab'
        Features = @(
            [pscustomobject]@{ Id = 'Demo'; Title = 'Demo driver'; Property = 'INSTALL_DEMO' },
            [pscustomobject]@{ Id = 'Dla'; Title = 'FNIRSI DLA-16 driver'; Property = 'INSTALL_DLA' })
    }
}

function Use-UiSetup([scriptblock]$Body) {
    $root = New-TempFolder
    $product = New-UiTestProduct
    $stage = Join-Path $root 'stage'
    New-Item -ItemType Directory -Force -Path "$stage\drivers" | Out-Null
    [System.IO.File]::WriteAllText("$stage\bitoscope_gui.exe", 'gui')
    [System.IO.File]::WriteAllText("$stage\drivers\demo.exe", 'demo')
    [System.IO.File]::WriteAllText("$stage\drivers\fnirsi_dla.exe", 'dla')
    $msi = Join-Path $root 'ui.msi'
    $process = $null
    $passed = $false
    try {
        New-MsiPackage -Stage $stage -OutputPath $msi -WorkFolder (Join-Path $root 'work') -Product $product `
            -FileFeatures @{ 'drivers\demo.exe' = @('Demo'); 'drivers\fnirsi_dla.exe' = @('Dla') }
        & $Body $root $product $msi
        $passed = $true
    } finally {
        if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
        if (-not $passed) {
            $logs = Join-Path ([System.IO.Path]::GetTempPath()) 'bitoscope-dist-uitest-logs'
            New-Item -ItemType Directory -Force -Path $logs | Out-Null
            Get-ChildItem -LiteralPath $root -Filter '*.log' -ErrorAction SilentlyContinue | Copy-Item -Destination $logs -Force
        }
        $quiet =Invoke-ProgramAndWait @{ FilePath = "$env:SystemRoot\System32\msiexec.exe"; ArgumentList = (ConvertTo-MsiexecArguments @('/x', $product.ProductCode, '/qn')) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:ProgramFiles $product.Folder) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'dialog install for me only into a chosen folder, finish, then uninstall' {
    Use-UiSetup {
        param($root, $product, $msi)
        $chosen = Join-Path $root 'chosen folder'
        $process = Start-Setup $msi (Join-Path $root 'ui.log')
        try {
            [void](Wait-Control $process 'Button' 'Next >')
            Select-Control (Wait-Control $process 'RadioButton' 'Only for me (no administrator rights needed)')
            Invoke-Control (Wait-Control $process 'Button' 'Next >')
            $folder = Wait-Control $process 'Edit' ''
            Assert-Equal (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)\") (Get-ControlValue $folder) 'default folder shown for me only'
            Set-ControlValue $folder "$chosen\"
            Invoke-Control (Wait-Control $process 'Button' 'Install')
            Invoke-Control (Wait-Control $process 'Button' 'Finish' 120)
            if (-not $process.WaitForExit(60000)) { throw 'installer did not end after Finish' }
            Assert-Equal 0 $process.ExitCode 'installer exit code'
        } finally { if (-not $process.HasExited) { $process.Kill() } }
        foreach ($relative in 'bitoscope_gui.exe', 'drivers\demo.exe', 'drivers\fnirsi_dla.exe') {
            if (-not (Test-Path -LiteralPath (Join-Path $chosen $relative))) { throw "no $relative in $chosen" }
        }
        if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)")) { throw 'default folder was used as well' }
        $uninstall = Invoke-ProgramAndWait @{ FilePath = "$env:SystemRoot\System32\msiexec.exe"; ArgumentList = (ConvertTo-MsiexecArguments @('/x', $msi, '/qn')) }
        Assert-Equal 0 $uninstall.ExitCode 'uninstall exit code'
        if (@(Get-ChildItem -LiteralPath $chosen -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) { throw "uninstall left files in $chosen" }
    }
}

function Install-WithDriverChoice([string[]]$ClearDrivers, [string[]]$Present, [string[]]$Absent) {
    Use-UiSetup {
        param($root, $product, $msi)
        $chosen = Join-Path $root 'drivers chosen'
        $process = Start-Setup $msi (Join-Path $root 'ui-drivers.log')
        try {
            Select-Control (Wait-Control $process 'RadioButton' 'Only for me (no administrator rights needed)')
            Invoke-Control (Wait-Control $process 'Button' 'Next >')
            Set-ControlValue (Wait-Control $process 'Edit' '') "$chosen\"
            foreach ($title in 'Demo driver', 'FNIRSI DLA-16 driver') {
                Assert-Equal 'On' (Get-ToggleState (Wait-Control $process 'CheckBox' $title)) "$title is chosen at start"
            }
            foreach ($title in $ClearDrivers) { Switch-Control (Wait-Control $process 'CheckBox' $title) }
            foreach ($title in $ClearDrivers) { Assert-Equal 'Off' (Get-ToggleState (Wait-Control $process 'CheckBox' $title)) "$title after click" }
            Invoke-Control (Wait-Control $process 'Button' 'Install')
            Invoke-Control (Wait-Control $process 'Button' 'Finish' 120)
            if (-not $process.WaitForExit(60000)) { throw 'installer did not end after Finish' }
            Assert-Equal 0 $process.ExitCode 'installer exit code'
        } finally { if (-not $process.HasExited) { $process.Kill() } }
        foreach ($relative in $Present) { if (-not (Test-Path -LiteralPath (Join-Path $chosen $relative))) { throw "no $relative in $chosen" } }
        foreach ($relative in $Absent) { if (Test-Path -LiteralPath (Join-Path $chosen $relative)) { throw "$relative was installed although its driver was cleared" } }
        $uninstall = Invoke-ProgramAndWait @{ FilePath = "$env:SystemRoot\System32\msiexec.exe"; ArgumentList = (ConvertTo-MsiexecArguments @('/x', $msi, '/qn')) }
        Assert-Equal 0 $uninstall.ExitCode 'uninstall exit code'
        if (@(Get-ChildItem -LiteralPath $chosen -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) { throw "uninstall left files in $chosen" }
    }
}

Test-Case 'dialog: clearing one driver leaves it out and installs the rest' {
    Install-WithDriverChoice @('Demo driver') @('bitoscope_gui.exe', 'drivers\fnirsi_dla.exe') @('drivers\demo.exe')
}

Test-Case 'dialog: clearing every driver installs application alone, without drivers folder' {
    Install-WithDriverChoice @('Demo driver', 'FNIRSI DLA-16 driver') @('bitoscope_gui.exe') @('drivers\demo.exe', 'drivers\fnirsi_dla.exe', 'drivers')
}

Test-Case 'dialog shows default folder of chosen scope and goes back' {
    Use-UiSetup {
        param($root, $product, $msi)
        $process = Start-Setup $msi (Join-Path $root 'ui2.log')
        try {
            Select-Control (Wait-Control $process 'RadioButton' 'All users of this computer (needs administrator rights)')
            Invoke-Control (Wait-Control $process 'Button' 'Next >')
            $folder = Wait-Control $process 'Edit' ''
            Assert-Equal (Join-Path $env:ProgramFiles "$($product.Folder)\") (Get-ControlValue $folder) 'default folder shown for all users'
            Invoke-Control (Wait-Control $process 'Button' '< Back')
            Select-Control (Wait-Control $process 'RadioButton' 'Only for me (no administrator rights needed)')
            Invoke-Control (Wait-Control $process 'Button' 'Next >')
            $folder = Wait-Control $process 'Edit' ''
            Assert-Equal (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)\") (Get-ControlValue $folder) 'default folder shown after going back'
            Invoke-Control (Wait-Control $process 'Button' 'Cancel')
            Invoke-Control (Wait-Control $process 'Button' 'Yes')
            Invoke-Control (Wait-Control $process 'Button' 'Finish')
            if (-not $process.WaitForExit(60000)) { throw 'installer did not end after cancel' }
            Assert-Equal 1602 $process.ExitCode 'exit code after cancel'
        } finally { if (-not $process.HasExited) { $process.Kill() } }
        if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)")) { throw 'cancel left default folder' }
        if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles $product.Folder)) { throw 'cancel left Program Files folder' }
    }
}

function Wait-MsiexecClient([string]$MsiName, [int]$Seconds = 60) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $until) {
        $client = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'msiexec.exe' -and $_.CommandLine -match [regex]::Escape($MsiName) -and $_.CommandLine -match '/i' })
        if ($client.Count -gt 0) { return (Get-Process -Id $client[0].ProcessId) }
        Start-Sleep -Milliseconds 300
    }
    throw "no msiexec client for $MsiName after $Seconds s"
}

function Use-UiExe([scriptblock]$ExeBody) {
    . (Join-Path $PSScriptRoot 'iexpress.ps1')
    Use-UiSetup {
        param($root, $product, $msi)
        $exe = Join-Path $root 'ui-setup.exe'
        try {
            New-IExpressPackage -MsiPath $msi -OutputPath $exe -WorkFolder (Join-Path $root 'iexpress') -FriendlyName "$($product.Name) Setup"
        } catch {
            $original = "$_ at $($_.ScriptStackTrace -replace '\r?\n', ' <- ')"
            $sedPath = Join-Path $root 'iexpress\setup.sed'
            $sed = if (Test-Path -LiteralPath $sedPath) { (Get-Content -LiteralPath $sedPath -Raw) -replace '(?s)^.*?\[Strings\]', '[Strings]' } else { 'no setup.sed' }
            $listing = (Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) }) -join ', '
            throw "$original; msi is '$msi' and exists: $(Test-Path -LiteralPath $msi); files: $listing; $sed"
        }
        & $ExeBody $root $product $exe
    }
}

Test-Case 'setup exe shows same dialog and installs for me only into default folder' {
    Use-UiExe {
        param($root, $product, $exe)
        $setup = Start-Process -FilePath $exe -PassThru
        $client = Wait-MsiexecClient 'ui.msi'
        try {
            Select-Control (Wait-Control $client 'RadioButton' 'Only for me (no administrator rights needed)')
            Invoke-Control (Wait-Control $client 'Button' 'Next >')
            Wait-Control $client 'Edit' '' | Out-Null
            Invoke-Control (Wait-Control $client 'Button' 'Install')
            Invoke-Control (Wait-Control $client 'Button' 'Finish' 120)
            if (-not $setup.WaitForExit(60000)) { throw 'setup exe did not end after Finish' }
            Assert-Equal 0 $setup.ExitCode 'setup exe exit code'
        } finally { if (-not $setup.HasExited) { $setup.Kill() } }
        $folder = Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)"
        if (-not (Test-Path -LiteralPath (Join-Path $folder 'bitoscope_gui.exe'))) { throw "no bitoscope_gui.exe in $folder" }
    }
}

Test-Case 'setup exe with /Q installs silently, for me only when not administrator' {
    Use-UiExe {
        param($root, $product, $exe)
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $setup = Start-Process -FilePath $exe -ArgumentList '/Q' -PassThru
        if (-not $setup.WaitForExit(120000)) { $setup.Kill(); throw 'silent setup exe did not end' }
        Assert-Equal 0 $setup.ExitCode 'silent setup exe exit code'
        $expected = if ($elevated) { Join-Path $env:ProgramFiles $product.Folder } else { Join-Path $env:LOCALAPPDATA "Programs\$($product.Folder)" }
        if (-not (Test-Path -LiteralPath (Join-Path $expected 'bitoscope_gui.exe'))) { throw "no bitoscope_gui.exe in $expected (elevated: $elevated)" }
    }
}

Test-Case 'dialog install for all users into Program Files (elevated runs only)' {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) { Write-Host '      skipped: not elevated'; return }
    Use-UiSetup {
        param($root, $product, $msi)
        $process = Start-Setup $msi (Join-Path $root 'ui3.log')
        try {
            Select-Control (Wait-Control $process 'RadioButton' 'All users of this computer (needs administrator rights)')
            Invoke-Control (Wait-Control $process 'Button' 'Next >')
            Assert-Equal (Join-Path $env:ProgramFiles "$($product.Folder)\") (Get-ControlValue (Wait-Control $process 'Edit' '')) 'default folder for all users'
            Invoke-Control (Wait-Control $process 'Button' 'Install')
            Invoke-Control (Wait-Control $process 'Button' 'Finish' 120)
            if (-not $process.WaitForExit(60000)) { throw 'installer did not end after Finish' }
            Assert-Equal 0 $process.ExitCode 'installer exit code'
        } finally { if (-not $process.HasExited) { $process.Kill() } }
        if (-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles "$($product.Folder)\bitoscope_gui.exe"))) { throw 'no bitoscope_gui.exe in Program Files' }
        $shortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$($product.Name).lnk"
        if (-not (Test-Path -LiteralPath $shortcut)) { throw "no all-users Start menu entry $shortcut" }
        $uninstall = Invoke-ProgramAndWait @{ FilePath = "$env:SystemRoot\System32\msiexec.exe"; ArgumentList = (ConvertTo-MsiexecArguments @('/x', $msi, '/qn')) }
        Assert-Equal 0 $uninstall.ExitCode 'uninstall exit code'
        if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles $product.Folder)) { throw 'uninstall left Program Files folder' }
    }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "$($script:Failures.Count) of $($script:Count) UI tests failed:"
    $script:Failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "All $($script:Count) UI tests passed."
