[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.6.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('agents-on-build-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $work 'Agents-On-Windows'
$dist = Join-Path $repo 'dist'
try {
    New-Item -ItemType Directory -Path $package, $dist -Force | Out-Null
    & dotnet publish (Join-Path $repo 'windows/AgentsOn.Windows/AgentsOn.Windows.csproj') `
        --configuration Release --runtime $Runtime --self-contained true --output $package `
        "-p:Version=$Version" -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:PublishReadyToRun=false -p:DebugType=None -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $package 'AgentsOn.exe'))) { throw 'Published app is missing.' }
    Copy-Item -LiteralPath (Join-Path $repo 'windows/install.ps1') -Destination $package
    Copy-Item -LiteralPath (Join-Path $repo 'windows/uninstall.ps1') -Destination $package
    Copy-Item -LiteralPath (Join-Path $repo 'README.md'), (Join-Path $repo 'LICENSE') -Destination $package
    $manifest = Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($package.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    }
    [IO.File]::WriteAllLines((Join-Path $package 'FILES.sha256'), [string[]]$manifest, [Text.UTF8Encoding]::new($false))
    $archive = Join-Path $dist "Agents-On-Windows-$Runtime.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -LiteralPath $package -DestinationPath $archive -CompressionLevel Optimal
    $checksum = '{0}  {1}' -f (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path $archive -Leaf)
    [IO.File]::WriteAllText("$archive.sha256", "$checksum`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Built $archive"
    Write-Host $checksum
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
