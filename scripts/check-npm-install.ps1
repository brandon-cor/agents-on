[CmdletBinding()]
param([string]$Reports = 'dist/npm-windows11')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reportRoot = [IO.Path]::GetFullPath($Reports)
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('agents on npm verification ' + [guid]::NewGuid().ToString('N'))
$steps = [Collections.Generic.List[object]]::new()
$evidence = [ordered]@{
    wrapperVersion = '0.7.1'; appVersion = '0.7.0'; status = 'running'; startedUtc = [DateTime]::UtcNow.ToString('o')
    os = $null; node = $null; npm = $null; package = $null; steps = $steps; errors = @()
}
$commandNumber = 0
$npmEnvironment = @{}
$installedRoot = $null
$installed = $null
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$installationAttempted = $false

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Record-Step([string]$Name, $Details = $null) {
    $steps.Add([ordered]@{ name = $Name; status = 'passed'; details = $Details })
    Write-Host "$Name`: passed"
}
function Invoke-Captured([string]$Exe, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds = 240) {
    $script:commandNumber++
    $prefix = '{0:00}-{1}' -f $script:commandNumber, $Name
    $stdoutPath = Join-Path $reportRoot "$prefix.out.log"
    $stderrPath = Join-Path $reportRoot "$prefix.err.log"
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false
    $info.WorkingDirectory = $work
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($entry in $npmEnvironment.GetEnumerator()) { $info.Environment[$entry.Key] = $entry.Value }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $stdoutFile = [IO.File]::Open($stdoutPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stderrFile = [IO.File]::Open($stderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $started = $false
    $copies = @()
    try {
        $started = $process.Start()
        if (-not $started) { throw "Could not start $Name." }
        $copies = @($process.StandardOutput.BaseStream.CopyToAsync($stdoutFile), $process.StandardError.BaseStream.CopyToAsync($stderrFile))
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Terminate only this test command; app cleanup is cooperative in the outer finally.
            $process.Kill(); $process.WaitForExit()
            throw "$Name timed out; see its command logs."
        }
        # A background GUI may inherit a console pipe. Do not wait indefinitely for its EOF.
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$copies, 3000)) {
            $process.StandardOutput.Close(); $process.StandardError.Close()
            try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$copies, 3000) | Out-Null } catch { }
        }
        $stdoutFile.Flush(); $stderrFile.Flush()
        if ($process.ExitCode -ne 0) { throw "$Name failed (exit $($process.ExitCode)); see $prefix logs." }
    } finally {
        if ($started) {
            $process.StandardOutput.Close(); $process.StandardError.Close()
            if ($copies.Count -gt 0) { try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$copies, 3000) | Out-Null } catch { } }
        }
        $stdoutFile.Dispose(); $stderrFile.Dispose(); $process.Dispose()
    }
    return [IO.File]::ReadAllText($stdoutPath).Trim()
}
function Assert-AppReady([string]$Name) {
    $text = Invoke-Captured $installed @('--check-ui') $Name 45
    $status = $text | ConvertFrom-Json
    Assert-True ($status.ok -and $status.visible -and $status.version -eq '0.7.0' -and -not $status.active -and $status.label -eq 'agents off') 'The npm-installed published app was not responsive, visible, version 0.7.0, and off.'
    return $status
}

try {
    Assert-True ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted') 'App installation checks require a disposable GitHub-hosted runner.'
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10
    $evidence.os = [ordered]@{
        caption = $os.Caption; productType = [int]$os.ProductType; build = [int]$os.BuildNumber
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        imageOS = $env:ImageOS; imageVersion = $env:ImageVersion
    }
    Assert-True ($os.Caption -match 'Windows 11' -and [int]$os.ProductType -eq 1 -and [int]$os.BuildNumber -ge 22000) 'This integration test requires Windows 11 client; Server is not accepted.'
    $installedRoot = Join-Path $env:LOCALAPPDATA 'Programs\Agents On'
    $installed = Join-Path $installedRoot 'AgentsOn.exe'
    $journal = Join-Path $env:LOCALAPPDATA 'Agents On\lid-recovery.json'
    Assert-True (-not (Test-Path -LiteralPath $installedRoot) -and -not (Test-Path -LiteralPath $journal)) 'The disposable profile must not have an existing app or pending lid recovery.'
    Assert-True ($null -eq (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue)) 'The disposable profile already has an Agents On login entry.'
    Record-Step 'windows11-disposable-host' $evidence.os

    New-Item -ItemType Directory -Path $work | Out-Null
    $cache = Join-Path $work 'cache with spaces'
    $prefix = Join-Path $work 'prefix with spaces'
    New-Item -ItemType Directory -Path $cache, $prefix | Out-Null
    $userConfig = Join-Path $work 'empty-user.npmrc'
    $globalConfig = Join-Path $work 'empty-global.npmrc'
    [IO.File]::WriteAllText($userConfig, '')
    [IO.File]::WriteAllText($globalConfig, '')
    $npmEnvironment = @{
        NPM_CONFIG_CACHE = $cache; NPM_CONFIG_PREFIX = $prefix
        NPM_CONFIG_USERCONFIG = $userConfig; NPM_CONFIG_GLOBALCONFIG = $globalConfig
        NPM_CONFIG_AUDIT = 'false'; NPM_CONFIG_FUND = 'false'; NPM_CONFIG_UPDATE_NOTIFIER = 'false'
        NPM_CONFIG_PROGRESS = 'false'; NPM_CONFIG_COLOR = 'false'
    }
    $node = (Get-Command node -CommandType Application -ErrorAction Stop).Source
    $npmCommand = Get-Command npm -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1
    $npmCandidates = @(
        (Join-Path (Split-Path $npmCommand.Source -Parent) 'node_modules/npm/bin/npm-cli.js'),
        (Join-Path (Split-Path $node -Parent) 'node_modules/npm/bin/npm-cli.js')
    )
    $npmCli = $npmCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    Assert-True ($null -ne $npmCli) 'Could not locate the actual npm CLI beside the installed Node/npm commands.'
    $evidence.node = Invoke-Captured $node @('--version') 'node-version' 30
    $evidence.npm = Invoke-Captured $node @($npmCli, '--version') 'npm-version' 30
    Assert-True ([int]($evidence.node.TrimStart('v').Split('.')[0]) -ge 20) 'The npm wrapper requires Node.js 20 or later.'
    $source = Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging/npm'
    $packText = Invoke-Captured $node @($npmCli, 'pack', $source, '--ignore-scripts', '--json', '--pack-destination', $work) 'npm-pack'
    $packs = @($packText | ConvertFrom-Json)
    Assert-True ($packs.Count -eq 1 -and $packs[0].name -eq 'agents-on' -and $packs[0].version -eq '0.7.1') 'npm did not pack the expected agents-on@0.7.1 package.'
    $filename = [string]$packs[0].filename
    Assert-True ([IO.Path]::GetFileName($filename) -ceq $filename) 'npm returned an unexpected tarball path.'
    $tarball = Join-Path $work $filename
    Assert-True (Test-Path -LiteralPath $tarball -PathType Leaf) 'The packed npm tarball is missing.'
    $evidence.package = [ordered]@{ name = $packs[0].name; version = $packs[0].version; bytes = (Get-Item -LiteralPath $tarball).Length; sha256 = (Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant(); pathsContainSpaces = $true }
    Record-Step 'actual-npm-tarball-packed' $evidence.package
    $exec = @($npmCli, 'exec', '--yes', '--package', $tarball, '--', 'agents-on')
    Invoke-Captured $node ($exec + @('--check')) 'npm-exec-check' | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $installedRoot) -and $null -eq (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue)) '--check unexpectedly created an app or startup entry.'
    Record-Step 'npm-exec-check-without-install' $null

    $installationAttempted = $true
    Invoke-Captured $node ($exec + @('install')) 'npm-exec-install' | Out-Null
    $status = Assert-AppReady 'installed-app-status'
    $startup = (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On').'Agents On'
    Assert-True ($startup -eq ('"' + $installed + '"')) 'The npm-installed app login entry points to the wrong executable.'
    Record-Step 'npm-exec-install-and-ready' $status
    Invoke-Captured $node ($exec + @('install')) 'npm-exec-upgrade' | Out-Null
    $status = Assert-AppReady 'upgraded-app-status'
    Record-Step 'npm-exec-running-app-upgrade' $status
    & (Join-Path $installedRoot 'uninstall.ps1')
    Assert-True (-not (Test-Path -LiteralPath $installed) -and $null -eq (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue)) 'Uninstall left the npm-installed app or login entry behind.'
    Record-Step 'cooperative-app-uninstall' $null
} catch {
    $evidence.errors += $_.Exception.Message
} finally {
    if ($installationAttempted -and $null -ne $installedRoot -and (Test-Path -LiteralPath (Join-Path $installedRoot 'uninstall.ps1'))) {
        try { & (Join-Path $installedRoot 'uninstall.ps1') }
        catch { $evidence.errors += "Cooperative app cleanup: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $work) {
        try { Remove-Item -LiteralPath $work -Recurse -Force }
        catch { $evidence.errors += "Private npm cache/prefix cleanup: $($_.Exception.Message)" }
    }
    $evidence.status = if ($evidence.errors.Count -eq 0) { 'passed' } else { 'failed' }
    $evidence.completedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $reportRoot 'evidence.json'), ($evidence | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
if ($evidence.status -ne 'passed') { throw ($evidence.errors -join '; ') }
Write-Host 'Packed npm installer verified on Windows 11; app stayed off and was uninstalled cooperatively.'
