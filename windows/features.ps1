# SPDX-License-Identifier: MIT

Set-StrictMode -Version 3

function Get-DriverFeatureDefinitions {
    return @(
        [pscustomobject]@{ Id = 'Demo'; Title = 'Demo driver (simulated signals, no hardware)'; Property = 'INSTALL_DEMO'; Program = 'demo.exe'; Repo = 'bitoscope' },
        [pscustomobject]@{ Id = 'Dla'; Title = 'FNIRSI DLA-16 driver'; Property = 'INSTALL_DLA'; Program = 'fnirsi_dla.exe'; Repo = 'bitoscope-fnirsi-dla' },
        [pscustomobject]@{ Id = 'Bridge'; Title = 'Sigrok bridge driver (USB analyzers supported by libsigrok)'; Property = 'INSTALL_SIGROK'; Program = 'sigrok_bridge.exe'; Repo = 'bitoscope-sigrok-bridge' },
        [pscustomobject]@{ Id = 'Fx2la'; Title = 'FX2LA driver (Cypress FX2 analyzers)'; Property = 'INSTALL_FX2LA'; Program = 'fx2la.exe'; Repo = 'bitoscope-fx2la' })
}

function Get-FileFeatures([string[]]$Relatives, [hashtable]$Owners, [scriptblock]$ImportsOf) {
    $definitions = @(Get-DriverFeatureDefinitions)
    $driverFiles = @{}
    foreach ($relative in $Relatives) {
        if ($relative.ToLowerInvariant().StartsWith('drivers\')) { $driverFiles[$relative.ToLowerInvariant()] = $relative }
    }
    $features = @{}
    function Add-Feature([string]$Key, [string]$Id) {
        if (-not $features.ContainsKey($Key)) { $features[$Key] = [System.Collections.Generic.List[string]]::new() }
        if (-not $features[$Key].Contains($Id)) { $features[$Key].Add($Id) }
    }
    foreach ($key in @($driverFiles.Keys)) {
        if ($key -notmatch '^drivers\\[^\\]+\.exe$') { continue }
        $program = $key.Substring('drivers\'.Length)
        $definition = @($definitions | Where-Object { $_.Program -eq $program })
        if ($definition.Count -ne 1) {
            throw "$($driverFiles[$key]) is a driver program that no feature offers: add it to Get-DriverFeatureDefinitions"
        }
        $visited = @{}
        $todo = [System.Collections.Generic.Queue[string]]::new()
        $todo.Enqueue($key)
        while ($todo.Count -gt 0) {
            $current = $todo.Dequeue()
            if ($visited.ContainsKey($current)) { continue }
            $visited[$current] = $true
            Add-Feature $current $definition[0].Id
            foreach ($item in @(& $ImportsOf $driverFiles[$current])) {
                foreach ($name in @($item)) {
                    $dependency = "drivers\$($name.ToLowerInvariant())"
                    if ($driverFiles.ContainsKey($dependency)) { $todo.Enqueue($dependency) }
                }
            }
        }
    }
    foreach ($key in @($driverFiles.Keys)) {
        if ($Owners.ContainsKey($key)) {
            foreach ($owner in @($Owners[$key])) {
                foreach ($definition in @($definitions | Where-Object { $_.Repo -eq $owner })) { Add-Feature $key $definition.Id }
            }
        }
        if (-not $features.ContainsKey($key)) {
            throw "$($driverFiles[$key]) belongs to no driver: no driver program loads it and no driver repository installed it"
        }
    }
    $result = @{}
    foreach ($key in $features.Keys) { $result[$key] = $features[$key].ToArray() }
    return $result
}

function Get-PackageFiles([string[]]$Relatives, [hashtable]$Features, [string]$Kind) {
    if ($Kind -eq 'all') { return @($Relatives) }
    if ($Kind -ne 'application' -and $null -eq (Get-DriverFeatureDefinitions | Where-Object { $_.Id -eq $Kind })) {
        throw "no package kind '$Kind'"
    }
    $wanted = if ($Kind -eq 'application') { 'Demo' } else { $Kind }
    $selected = foreach ($relative in $Relatives) {
        $key = $relative.ToLowerInvariant()
        $isLicence = $key.StartsWith('licenses\')
        if (-not $Features.ContainsKey($key)) {
            if ($Kind -eq 'application' -or $isLicence) { $relative }
        } elseif ($wanted -in @($Features[$key])) {
            $relative
        }
    }
    return @($selected)
}

function New-FilesZip([string]$Stage, [string[]]$Relatives, [string]$ZipPath, [string]$BaseFolder) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = (Resolve-Path -LiteralPath $Stage).Path.TrimEnd('\')
    foreach ($relative in $Relatives) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) { throw "$relative is not in $root" }
    }
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in ($Relatives | Sort-Object)) {
            $entry = "$BaseFolder/" + $relative.Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $root $relative), $entry,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $archive.Dispose()
    }
}

function Save-FileFeatures([hashtable]$Map, [string]$Path) {
    $entries = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object)) { $entries[$key] = @($Map[$key]) }
    [System.IO.File]::WriteAllText($Path, ($entries | ConvertTo-Json -Depth 3), [System.Text.Encoding]::ASCII)
}

function Read-FileFeatures([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "no feature map at ${Path}: run target stage first" }
    $result = @{}
    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($property in $parsed.PSObject.Properties) { $result[$property.Name] = @($property.Value) }
    return $result
}
