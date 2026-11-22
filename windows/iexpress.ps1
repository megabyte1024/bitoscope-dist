# SPDX-License-Identifier: MIT

Set-StrictMode -Version 3

function ConvertTo-SedText([string]$MsiPath, [string]$OutputPath, [string]$FriendlyName) {
    $msiName = Split-Path -Leaf $MsiPath
    $msiFolder = (Split-Path -Parent $MsiPath).TrimEnd('\') + '\'
    foreach ($value in @($msiName, $msiFolder, $OutputPath, $FriendlyName)) {
        if ($value -match '["%\r\n]') { throw "IExpress cannot take value with quote, percent sign or line break: $value" }
    }
    if ($msiName -match '\s') { throw "package name must have no spaces: $msiName" }
    $quiet = "cmd /c start /wait msiexec.exe /i $msiName /qn & if errorlevel 1 if not errorlevel 1641 start /wait msiexec.exe /i $msiName /qn MSIINSTALLPERUSER=1"
    $lines = @(
        '[Version]',
        'Class=IEXPRESS',
        'SEDVersion=3',
        '[Options]',
        'PackagePurpose=InstallApp',
        'ShowInstallProgramWindow=1',
        'HideExtractAnimation=1',
        'UseLongFileName=1',
        'InsideCompressed=0',
        'CAB_FixedSize=0',
        'CAB_ResvCodeSigning=0',
        'RebootMode=N',
        'InstallPrompt=%InstallPrompt%',
        'DisplayLicense=%DisplayLicense%',
        'FinishMessage=%FinishMessage%',
        'TargetName=%TargetName%',
        'FriendlyName=%FriendlyName%',
        'AppLaunched=%AppLaunched%',
        'PostInstallCmd=%PostInstallCmd%',
        'AdminQuietInstCmd=%AdminQuietInstCmd%',
        'UserQuietInstCmd=%UserQuietInstCmd%',
        'SourceFiles=SourceFiles',
        '[Strings]',
        'InstallPrompt=',
        'DisplayLicense=',
        'FinishMessage=',
        "TargetName=$OutputPath",
        "FriendlyName=$FriendlyName",
        "AppLaunched=msiexec.exe /i $msiName",
        'PostInstallCmd=<None>',
        "AdminQuietInstCmd=$quiet",
        "UserQuietInstCmd=$quiet",
        "FILE0=`"$msiName`"",
        '[SourceFiles]',
        "SourceFiles0=$msiFolder",
        '[SourceFiles0]',
        '%FILE0%=')
    return ($lines -join "`r`n") + "`r`n"
}

function New-IExpressPackage {
    param(
        [Parameter(Mandatory)] [string]$MsiPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$WorkFolder,
        [Parameter(Mandatory)] [string]$FriendlyName
    )
    New-Item -ItemType Directory -Force -Path $WorkFolder | Out-Null
    $sed = Join-Path $WorkFolder 'setup.sed'
    [System.IO.File]::WriteAllText($sed, (ConvertTo-SedText $MsiPath $OutputPath $FriendlyName), [System.Text.Encoding]::ASCII)
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    $process = Invoke-ProgramAndWait @{
        FilePath = "$env:SystemRoot\System32\iexpress.exe"
        ArgumentList = '/N /Q setup.sed'
        WorkingDirectory = $WorkFolder
        NoNewWindow = $true
    }
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "iexpress failed (exit $($process.ExitCode)) for $sed"
    }
}
