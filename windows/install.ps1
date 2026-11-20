[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.6.0',
    [string]$ArchivePath,
    [switch]$CheckOnly,
    [switch]$SkipStartup,
    [switch]$DesktopShortcut
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Agents On for Windows requires Windows.' }
# TLS 1.2 is needed by Windows PowerShell 5.1 when downloading from GitHub.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$architecture = $env:PROCESSOR_ARCHITEW6432
if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
switch ($architecture.ToUpperInvariant()) {
    'AMD64' { $runtime = 'win-x64' }
    'ARM64' { $runtime = 'win-arm64' }
    default { throw 'Agents On requires 64-bit Windows on Intel/AMD or ARM64.' }
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('agents-on-install-' + [guid]::NewGuid().ToString('N'))
$parent = Join-Path $env:LOCALAPPDATA 'Programs'
$target = Join-Path $parent 'Agents On'
$binary = Join-Path $target 'AgentsOn.exe'
$staged = Join-Path $parent ('Agents On.staging.' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $parent ('Agents On.backup.' + [guid]::NewGuid().ToString('N'))
$hasBackup = $false
$replaced = $false
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupChanged = $false
$startupExisted = $false
$startupValue = $null
$startupKind = 'String'
$shortcutBackups = @()
function Wait-AppExit([string]$Exe) {
    $until = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $running = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue | Where-Object {
            try { $_.MainModule.FileName -ieq $Exe } catch { $false }
        })
        if ($running.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw 'Agents On is still restoring sleep settings. Wait for it to finish before updating.'
}
function Invoke-AppCommand([string]$Exe, [string]$Command) {
    $process = Start-Process -FilePath $Exe -ArgumentList $Command -PassThru
    if (-not $process.WaitForExit(15000)) { throw "The app did not finish $Command. Close Agents On and retry." }
    if ($process.ExitCode -ne 0) { throw "The app could not complete $Command (exit $($process.ExitCode))." }
}
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $package = $null
    if ($ArchivePath) {
        $archive = (Resolve-Path -LiteralPath $ArchivePath).Path
        $sidecar = "$archive.sha256"
        if (-not (Test-Path -LiteralPath $sidecar)) { throw "Missing checksum: $sidecar" }
    } elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'AgentsOn.exe'))) {
        # An extracted portable release includes its own file-integrity manifest.
        $package = $PSScriptRoot
    } else {
        $name = "Agents-On-Windows-$runtime.zip"
        $base = "https://github.com/brandon-cor/agents-on/releases/download/v$Version"
        $archive = Join-Path $work $name
        $sidecar = "$archive.sha256"
        Write-Host "Downloading Agents On $Version ($runtime)..."
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $archive
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$name.sha256" -OutFile $sidecar
    }
    if (-not $package) {
        $checksumLine = [IO.File]::ReadAllText($sidecar).Trim()
        if ($checksumLine -notmatch '^([a-fA-F0-9]{64})\s+\*?([^\r\n]+)$') { throw 'Invalid release checksum file.' }
        $expectedHash = $Matches[1]
        if ((Split-Path $archive -Leaf) -cne $Matches[2]) { throw 'Checksum names a different archive.' }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) { throw 'Release checksum mismatch; nothing was installed.' }
        $unpacked = Join-Path $work 'unpacked'
        Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
        $package = Join-Path $unpacked 'Agents-On-Windows'
    }
    $manifestPath = Join-Path $package 'FILES.sha256'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'The package integrity manifest is missing.' }
    $verified = @{}
    foreach ($line in [IO.File]::ReadAllLines($manifestPath)) {
        if ($line -notmatch '^([a-fA-F0-9]{64})  (.+)$') { throw 'Invalid package manifest.' }
        $hash = $Matches[1]
        $relative = $Matches[2]
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe package path.' }
        $file = Join-Path $package $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $hash) { throw "Package file failed verification: $relative" }
        $verified[$relative] = $true
    }
    foreach ($required in @('AgentsOn.exe', 'uninstall.ps1')) {
        if (-not $verified.ContainsKey($required)) { throw "Missing verified package file: $required" }
    }
    if ($CheckOnly) { Write-Host 'Windows package verified. No installation or power settings changed.'; return }
    New-Item -ItemType Directory -Path $parent, $staged -Force | Out-Null
    foreach ($name in @('AgentsOn.exe', 'uninstall.ps1')) { Copy-Item -LiteralPath (Join-Path $package $name) -Destination $staged }
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "The existing folder is not a recognized Agents On installation: $target"
    }
    if (Test-Path -LiteralPath $binary) { Invoke-AppCommand $binary '--quit'; Wait-AppExit $binary }
    if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $backup; $hasBackup = $true }
    Move-Item -LiteralPath $staged -Destination $target
    $replaced = $true
    Start-Process -FilePath $binary | Out-Null
    Invoke-AppCommand $binary '--check-ui'
    $quotedBinary = '"' + $binary + '"'
    if (-not $SkipStartup) {
        New-Item -Path $runKey -Force | Out-Null
        $oldStartup = Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue
        if ($null -ne $oldStartup) {
            $startupExisted = $true
            $startupValue = $oldStartup.'Agents On'
            $startupKind = (Get-Item -LiteralPath $runKey).GetValueKind('Agents On').ToString()
        }
        $startupChanged = $true
        New-ItemProperty -LiteralPath $runKey -Name 'Agents On' -Value $quotedBinary -PropertyType String -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcutFolders = @([Environment]::GetFolderPath('Programs'))
    if ($DesktopShortcut) { $shortcutFolders += [Environment]::GetFolderPath('Desktop') }
    foreach ($shortcutFolder in $shortcutFolders) {
        $shortcutPath = Join-Path $shortcutFolder 'Agents On.lnk'
        $savedLink = Join-Path $work ('shortcut-' + $shortcutBackups.Count + '.lnk')
        $existed = Test-Path -LiteralPath $shortcutPath
        if ($existed) { Copy-Item -LiteralPath $shortcutPath -Destination $savedLink }
        $shortcutBackups += @{ Path = $shortcutPath; Backup = $savedLink; Existed = $existed }
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $binary
        $shortcut.WorkingDirectory = $target
        $shortcut.Description = 'Keep your computer awake while your agents work.'
        $shortcut.Save()
    }
    if ($hasBackup) {
        $hasBackup = $false
        try { Remove-Item -LiteralPath $backup -Recurse -Force }
        catch { Write-Warning "The app was updated, but its old backup remains at $backup" }
    }
    Write-Host 'Installed Agents On. Look for its green or gray light near the clock.'
    Write-Host 'If hidden, open the tray arrow and drag Agents On beside the clock.'
    Write-Host 'Left-click toggles keep-awake; right-click opens timers and options.'
    Write-Host "Uninstall: & '$target\uninstall.ps1'"
} catch {
    $failure = $_
    # Restore startup and shortcuts if a later installation step fails.
    if ($startupChanged) {
        try {
            if ($startupExisted) {
                New-ItemProperty -LiteralPath $runKey -Name 'Agents On' -Value $startupValue -PropertyType $startupKind -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue
            }
        } catch { Write-Warning "Could not restore startup settings: $($_.Exception.Message)" }
    }
    foreach ($link in $shortcutBackups) {
        try {
            if ($link.Existed) { Copy-Item -LiteralPath $link.Backup -Destination $link.Path -Force }
            elseif (Test-Path -LiteralPath $link.Path) { Remove-Item -LiteralPath $link.Path -Force }
        } catch { Write-Warning "Could not restore shortcut: $($_.Exception.Message)" }
    }
    if ($replaced) {
        $canRestore = $true
        try { Invoke-AppCommand $binary '--quit'; Wait-AppExit $binary } catch {
            $canRestore = $false
            Write-Warning "Agents On is still running; its files were preserved. Close it before retrying. Backup: $backup"
        }
        if (-not $canRestore) { throw $failure }
        if ($hasBackup) {
            try {
                Remove-Item -LiteralPath $target -Recurse -Force
                Move-Item -LiteralPath $backup -Destination $target
                $hasBackup = $false
                Start-Process -FilePath $binary | Out-Null
                Write-Warning 'The update failed; the previous app was restored.'
            } catch { Write-Warning "Previous app remains at $backup. $($_.Exception.Message)" }
        } else {
            try { Remove-Item -LiteralPath $target -Recurse -Force } catch { Write-Warning $_ }
        }
    } elseif ($hasBackup) {
        Move-Item -LiteralPath $backup -Destination $target
        $hasBackup = $false
        Start-Process -FilePath $binary | Out-Null
    }
    throw $failure
} finally {
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
