# SPDX-License-Identifier: MIT

Set-StrictMode -Version 3

$script:VisualCppRuntime = '^(msvcp|vcruntime|concrt|vccorlib|vcomp)\d'
$script:ApiSet = '^(api|ext)-ms-'

function Read-Manifest([string]$Path) {
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') {
        throw "manifest version '$($manifest.version)' is not MAJOR.MINOR.PATCH"
    }
    foreach ($name in @('bitoscope', 'bitoscope-fnirsi-dla', 'bitoscope-sigrok-bridge')) {
        $repo = @($manifest.repos | Where-Object { $_.name -eq $name })
        if ($repo.Count -ne 1) { throw "manifest must name repo $name once" }
        if ($repo[0].commit -notmatch '^[0-9a-f]{40}$') { throw "manifest: commit of $name is not 40 hex digits" }
        if ([string]::IsNullOrEmpty((Get-Field $repo[0] 'url')) -or
            ([string]::IsNullOrEmpty((Get-Field $repo[0] 'tag')) -and [string]::IsNullOrEmpty((Get-Field $repo[0] 'branch')))) {
            throw "manifest: $name needs url and tag or branch"
        }
    }
    return $manifest
}

function Get-Field($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ManifestRepo($Manifest, [string]$Name) {
    return @($Manifest.repos | Where-Object { $_.name -eq $Name })[0]
}

function Get-RefText($Repo) {
    $tag = Get-Field $Repo 'tag'
    if (-not [string]::IsNullOrEmpty($tag)) { return "tag $tag" }
    return "branch $(Get-Field $Repo 'branch')"
}

function Get-Naming($Manifest) {
    if ((Get-Field $Manifest 'nightly') -eq $true) {
        return [pscustomobject]@{
            Name = 'Bitoscope Nightly'
            Base = 'bitoscope-nightly'
            UpgradeCode = '{5B0F5448-17C3-4625-8FE1-DB6713DEBC75}'
        }
    }
    return [pscustomobject]@{
        Name = 'Bitoscope'
        Base = "bitoscope-$($Manifest.version)"
        UpgradeCode = '{140CE35C-0B96-4A07-83C9-03B4E1B59042}'
    }
}

function ConvertTo-ArgumentText([string[]]$Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -ne '' -and $argument -notmatch '[\s"]') {
            $argument
        } else {
            $escaped = [regex]::Replace($argument, '(\\*)"', { param($m) $m.Groups[1].Value * 2 + '\"' })
            $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
            '"' + $escaped + '"'
        }
    }
    return $quoted -join ' '
}

$script:StepNumber = 0

function Invoke-Step {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Program,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{},
        [Parameter(Mandatory)] [string]$Logs
    )
    $script:StepNumber++
    Write-Host "==> $Title"
    New-Item -ItemType Directory -Force -Path $Logs | Out-Null
    $slug = ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $log = Join-Path $Logs ('{0:D2}-{1}' -f $script:StepNumber, $slug)
    $saved = @{}
    foreach ($name in $Environment.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $Environment[$name])
    }
    try {
        $argumentText = ConvertTo-ArgumentText $Arguments
        [System.IO.File]::WriteAllText("$log.cmd.txt", "$Program $argumentText`r`n")
        $startArguments = @{
            FilePath = $Program
            WorkingDirectory = $WorkingDirectory
            RedirectStandardOutput = "$log.out.txt"
            RedirectStandardError = "$log.err.txt"
            NoNewWindow = $true
            Wait = $true
            PassThru = $true
        }
        if ($argumentText -ne '') { $startArguments.ArgumentList = $argumentText }
        $process = Start-Process @startArguments
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
    if ($process.ExitCode -ne 0) {
        $tail = @(Get-Content -LiteralPath "$log.out.txt", "$log.err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 40)
        throw "$Title failed (exit $($process.ExitCode)); full output in $log.*.txt:`n$($tail -join "`n")"
    }
}

function Get-GitOutput([string]$Folder, [string[]]$Arguments) {
    $output = & git -C $Folder @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in $Folder" }
    return ($output -join "`n").Trim()
}

function Sync-Repo($Repo, [string]$Folder, [string]$Logs) {
    $git = (Get-Command git -ErrorAction Stop).Source
    if (Test-Path -LiteralPath (Join-Path $Folder '.git')) {
        $head = & git -C $Folder rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $head -eq $Repo.commit) {
            Write-Host "==> $($Repo.name) is at $($Repo.tag) ($($Repo.commit))"
            return
        }
        Remove-Item -LiteralPath $Folder -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    Invoke-Step "Init $($Repo.name)" $git @('init', '--quiet', $Folder) -Logs $Logs
    $tag = Get-Field $Repo 'tag'
    if (-not [string]::IsNullOrEmpty($tag)) {
        Invoke-Step "Fetch $($Repo.name) $tag" $git @('-C', $Folder, 'fetch', '--quiet', '--depth', '1', $Repo.url,
            "+refs/tags/$($tag):refs/tags/$tag") -Logs $Logs
        $tagged = Get-GitOutput $Folder @('rev-parse', "refs/tags/$tag^{commit}")
        if ($tagged -ne $Repo.commit) {
            throw "tag $tag of $($Repo.url) is commit $tagged, manifest names $($Repo.commit)"
        }
        $checkout = "refs/tags/$tag"
    } else {
        Invoke-Step "Fetch $($Repo.name) $(Get-Field $Repo 'branch') at $($Repo.commit.Substring(0, 12))" $git @('-C', $Folder,
            'fetch', '--quiet', '--depth', '1', $Repo.url, $Repo.commit) -Logs $Logs
        $checkout = 'FETCH_HEAD'
    }
    Invoke-Step "Check out $($Repo.name)" $git @('-C', $Folder, 'checkout', '--quiet', '--detach', $checkout) -Logs $Logs
    Invoke-Step "Submodules of $($Repo.name)" $git @('-C', $Folder, 'submodule', 'update', '--init', '--recursive',
        '--depth', '1') -Logs $Logs
}

function Get-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "no vswhere.exe: install Visual Studio 2022 or its Build Tools" }
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrEmpty($path)) { throw 'no Visual Studio with C++ tools (Desktop development with C++)' }
    $auxiliary = Join-Path $path 'VC\Auxiliary\Build'
    $tools = (Get-Content -LiteralPath (Join-Path $auxiliary 'Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $redist = (Get-Content -LiteralPath (Join-Path $auxiliary 'Microsoft.VCRedistVersion.default.txt') -Raw).Trim()
    $dumpbin = Join-Path $path "VC\Tools\MSVC\$tools\bin\Hostx64\x64\dumpbin.exe"
    $runtime = @(Get-ChildItem -LiteralPath (Join-Path $path "VC\Redist\MSVC\$redist\x64") -Directory -Filter 'Microsoft.VC*.CRT')
    if (-not (Test-Path -LiteralPath $dumpbin)) { throw "no dumpbin.exe at $dumpbin" }
    if ($runtime.Count -ne 1) { throw "no single Microsoft.VC*.CRT folder under $path\VC\Redist\MSVC\$redist\x64" }
    return [pscustomobject]@{ Path = $path; Dumpbin = $dumpbin; Runtime = $runtime[0].FullName; RedistVersion = $redist }
}

function ConvertFrom-DumpbinDependents([string]$Text) {
    $names = [System.Collections.Generic.List[string]]::new()
    $inList = $false
    $inSection = 0
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match 'Image has the following (delay load )?dependencies:') {
            $inList = $true
            $inSection = 0
            continue
        }
        if ($inList) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '') {
                if ($inSection -gt 0) { $inList = $false }
                continue
            }
            if ($trimmed -match '^Summary') { break }
            $names.Add($trimmed)
            $inSection++
        }
    }
    return , $names.ToArray()
}

function Get-Imports([string]$Dumpbin, [string]$Path) {
    $output = & $Dumpbin /NOLOGO /DEPENDENTS $Path
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $Path" }
    return , (ConvertFrom-DumpbinDependents ($output -join "`n"))
}

function Get-Binaries([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' } |
        Sort-Object FullName)
}

function Add-VisualCppRuntime([string]$Root, [string]$RuntimeFolder, [scriptblock]$ImportsOf) {
    $available = @{}
    foreach ($file in Get-ChildItem -LiteralPath $RuntimeFolder -File -Filter '*.dll') {
        $available[$file.Name.ToLowerInvariant()] = $file.FullName
    }
    $added = [System.Collections.Generic.List[string]]::new()
    do {
        $changed = $false
        foreach ($binary in Get-Binaries $Root) {
            foreach ($name in (& $ImportsOf $binary.FullName)) {
                if ($name -notmatch $script:VisualCppRuntime) { continue }
                $target = Join-Path $binary.DirectoryName $name
                if (Test-Path -LiteralPath $target) { continue }
                $source = $available[$name.ToLowerInvariant()]
                if ($null -eq $source) { throw "$($binary.FullName) needs $name, which $RuntimeFolder does not hold" }
                Copy-Item -LiteralPath $source -Destination (Join-Path $binary.DirectoryName (Split-Path -Leaf $source))
                $added.Add($target.Substring($Root.Length + 1))
                $changed = $true
            }
        }
    } while ($changed)
    return , $added.ToArray()
}

function Find-MissingDlls([string]$Root, [string]$SystemFolder, [scriptblock]$ImportsOf) {
    $Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $system = @{}
    foreach ($file in Get-ChildItem -LiteralPath $SystemFolder -File -Filter '*.dll' -ErrorAction SilentlyContinue) {
        $system[$file.Name.ToLowerInvariant()] = $true
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($binary in Get-Binaries $Root) {
        $beside = @{}
        foreach ($file in Get-ChildItem -LiteralPath $binary.DirectoryName -File) { $beside[$file.Name.ToLowerInvariant()] = $true }
        foreach ($name in (& $ImportsOf $binary.FullName)) {
            $key = $name.ToLowerInvariant()
            if ($beside.ContainsKey($key) -or $name -match $script:ApiSet) { continue }
            if ($system.ContainsKey($key) -and $name -notmatch $script:VisualCppRuntime) { continue }
            $problems.Add("$($binary.FullName.Substring($Root.Length + 1)) needs $name, found nowhere it would be loaded from")
        }
    }
    return , $problems.ToArray()
}

function Merge-Tree([string]$Source, [string]$Destination, [string]$Owner, [hashtable]$Owners) {
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        $target = Join-Path $Destination $relative
        if (Test-Path -LiteralPath $target) {
            $same = (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash
            if (-not $same) { throw "$relative is installed by $($Owners[$relative.ToLowerInvariant()]) and $Owner with different content" }
            continue
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $Owners[$relative.ToLowerInvariant()] = $Owner
    }
}

function Get-Plugins([string]$Root) {
    $names = foreach ($folder in @('drivers', 'decoders')) {
        $path = Join-Path $Root $folder
        if (Test-Path -LiteralPath $path) {
            Get-ChildItem -LiteralPath $path -File -Filter '*.exe' | ForEach-Object { $_.BaseName }
        }
    }
    return @($names | Sort-Object)
}

function Find-UnlistedPlugins([string[]]$Plugins, [string]$Listing) {
    return @($Plugins | Where-Object { $Listing -notmatch "(?m)^$([regex]::Escape($_))(?=[ :]|\r?$)" })
}

function New-BareEnvironment([string]$HomeFolder) {
    $folders = [ordered]@{
        USERPROFILE = $HomeFolder
        APPDATA = Join-Path $HomeFolder 'AppData\Roaming'
        LOCALAPPDATA = Join-Path $HomeFolder 'AppData\Local'
        TEMP = Join-Path $HomeFolder 'Temp'
        TMP = Join-Path $HomeFolder 'Temp'
    }
    foreach ($folder in $folders.Values) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    $environment = @{
        PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        SystemRoot = $env:SystemRoot
        SystemDrive = $env:SystemDrive
    }
    foreach ($name in $folders.Keys) { $environment[$name] = $folders[$name] }
    return $environment
}

function Invoke-PluginListing([string]$Checker, [string]$HomeFolder, [int]$TimeoutSeconds = 180) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($Checker, '--list-devices')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = Split-Path -Parent $Checker
    $info.EnvironmentVariables.Clear()
    $bare = New-BareEnvironment $HomeFolder
    foreach ($name in $bare.Keys) { $info.EnvironmentVariables[$name] = $bare[$name] }
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "$Checker --list-devices did not finish in $TimeoutSeconds s"
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
}

function Test-Distribution([string]$Root, [string]$Checker, [string]$Dumpbin, [string]$HomeFolder) {
    $importsOf = { param($path) Get-Imports $Dumpbin $path }.GetNewClosure()
    $problems = @(Find-MissingDlls $Root "$env:SystemRoot\System32" $importsOf)
    $gui = Join-Path $Root 'bitoscope_gui.exe'
    if (-not (Test-Path -LiteralPath $gui)) { $problems += 'bitoscope_gui.exe is missing' }
    elseif ([System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($gui)).Contains('BITOSCOPE_TEST_INPUT')) {
        $problems += 'bitoscope_gui.exe was built with test hook'
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'bitoscope_cli.exe')) { $problems += 'bitoscope_cli.exe is in distribution' }
    if ($problems.Count -gt 0) { throw "distribution in $Root failed checks:`n  $($problems -join "`n  ")" }

    $placed = Join-Path $Root 'bitoscope_cli.exe'
    Copy-Item -LiteralPath $Checker -Destination $placed
    try {
        Write-Host "==> List plugins of $Root with bare environment"
        $result = Invoke-PluginListing $placed $HomeFolder
    } finally {
        Remove-Item -LiteralPath $placed -Force
    }
    if ($result.ExitCode -ne 0) { throw "bitoscope_cli --list-devices exited $($result.ExitCode):`n$($result.Output)" }
    $unlisted = @(Find-UnlistedPlugins (Get-Plugins $Root) $result.Output)
    if ($unlisted.Count -gt 0) { throw "bitoscope_cli --list-devices does not list $($unlisted -join ', '):`n$($result.Output)" }
}
