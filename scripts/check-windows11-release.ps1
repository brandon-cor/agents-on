[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.7.0',
    [ValidateSet('win-arm64', 'win-x64')][string]$Runtime = 'win-arm64',
    [string]$Reports = "dist/windows11-$Runtime"
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reportRoot = [IO.Path]::GetFullPath($Reports)
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('agents-on-win11-' + [guid]::NewGuid().ToString('N'))
$installedRoot = $null
$installed = $null
$appData = $null
$journal = $null
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$steps = [Collections.Generic.List[object]]::new()
$evidence = [ordered]@{
    version = $Version; runtime = $Runtime; status = 'running'; startedUtc = [DateTime]::UtcNow.ToString('o')
    os = $null; assets = $null; originalPower = $null; restoredPower = $null; steps = $steps; errors = @()
}
$commandNumber = 0
$ownedPaths = [Collections.Generic.List[string]]::new()
$originalPower = $null
$powerTouched = $false
$installationStarted = $false
$failure = $null
$lidUnavailable = $null

function Record-Step([string]$Name, [string]$Status, $Details = $null) {
    $steps.Add([ordered]@{ name = $Name; status = $Status; details = $Details })
    Write-Host "$Name`: $Status"
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Download-Asset([string]$Name, [string]$Destination) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/brandon-cor/agents-on/releases/download/v$Version/$Name" -OutFile $Destination -TimeoutSec 180
            return
        } catch {
            if ($attempt -eq 3) { throw "Could not download the published $Name asset." }
            Start-Sleep -Seconds 2
        }
    }
}
function Invoke-App([string]$Exe, [string]$Command, [int]$TimeoutSeconds = 40) {
    $script:commandNumber++
    $name = '{0:00}-{1}' -f $script:commandNumber, $Command.TrimStart('-')
    $stdout = Join-Path $reportRoot "$name.out.log"
    $stderr = Join-Path $reportRoot "$name.err.log"
    $process = Start-Process -FilePath $Exe -ArgumentList $Command -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # This is the command process we just created, never the running tray owner.
            $process.Kill($true); $process.WaitForExit()
            throw "Published $Command command timed out."
        }
        if ($process.ExitCode -ne 0) { throw "Published $Command command failed (exit $($process.ExitCode)); see $name logs." }
        return [IO.File]::ReadAllText($stdout).Trim()
    } finally { $process.Dispose() }
}
function App-Status([string]$Exe) {
    $status = (Invoke-App $Exe '--check-ui') | ConvertFrom-Json
    Assert-True ($status.ok -and $status.visible -and $status.version -eq $Version) 'The published tray app did not report the expected version and visible indicator.'
    return $status
}
function Owned-Processes([string]$Exe) {
    @(Get-CimInstance Win32_Process -Filter "Name = 'AgentsOn.exe'" -OperationTimeoutSec 5 | Where-Object { $_.ExecutablePath -ieq $Exe })
}
function Wait-OwnedExit([string]$Exe) {
    $until = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if (@(Owned-Processes $Exe).Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw 'A fixture-owned app or recovery helper did not exit.'
}
function Power-Record($Value) {
    [ordered]@{ scheme = $Value.Scheme.ToString(); ac = $Value.Ac; dc = $Value.Dc }
}
function Wait-Power([uint32]$Ac, [uint32]$Dc, [bool]$JournalMustBeGone = $false) {
    $until = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Assert-True ([AgentsOnWin11Power]::ActiveScheme() -eq $originalPower.Scheme) 'The active power plan changed during the integration test.'
        $current = [AgentsOnWin11Power]::Read($originalPower.Scheme)
        if ($current.Ac -eq $Ac -and $current.Dc -eq $Dc -and (-not $JournalMustBeGone -or -not (Test-Path -LiteralPath $journal))) { return $current }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "The expected AC/DC lid actions $Ac/$Dc were not restored in time."
}

try {
    Assert-True ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted') 'Power fixtures are restricted to a disposable GitHub-hosted runner.'
    $installedRoot = Join-Path $env:LOCALAPPDATA 'Programs\Agents On'
    $installed = Join-Path $installedRoot 'AgentsOn.exe'
    $appData = Join-Path $env:LOCALAPPDATA 'Agents On'
    $journal = Join-Path $appData 'lid-recovery.json'
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10
    $currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $evidence.os = [ordered]@{
        caption = $os.Caption; productType = [int]$os.ProductType; build = [int]$os.BuildNumber
        displayVersion = $currentVersion.DisplayVersion; ubr = $currentVersion.UBR
        osArchitecture = $osArch; processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        imageOS = $env:ImageOS; imageVersion = $env:ImageVersion
    }
    Assert-True ($os.Caption -match 'Windows 11' -and [int]$os.ProductType -eq 1 -and [int]$os.BuildNumber -ge 22000) 'This test requires actual Windows 11 client; Windows Server is not accepted.'
    Assert-True ($osArch -eq 'Arm64') 'This workflow requires a Windows 11 ARM64 host.'
    Assert-True (-not (Test-Path -LiteralPath $installedRoot) -and -not (Test-Path -LiteralPath $appData)) 'This test requires a fresh disposable user profile with no existing Agents On installation or recovery record.'
    Record-Step 'actual-windows11-host' 'passed' $evidence.os

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class AgentsOnWin11LidValues
{
    public Guid Scheme { get; set; }
    public uint Ac { get; set; }
    public uint Dc { get; set; }
}
public static class AgentsOnWin11Power
{
    private static readonly Guid Buttons = new Guid("4f971e89-eebd-4455-a8de-9e59040e7347");
    private static readonly Guid Lid = new Guid("5ca83367-6e45-459f-a27b-476b1d01c936");
    [DllImport("powrprof.dll")] private static extern uint PowerGetActiveScheme(IntPtr key, out IntPtr scheme);
    [DllImport("powrprof.dll")] private static extern uint PowerReadACValueIndex(IntPtr key, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerReadDCValueIndex(IntPtr key, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerWriteACValueIndex(IntPtr key, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerWriteDCValueIndex(IntPtr key, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerSetActiveScheme(IntPtr key, ref Guid scheme);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    private static void Check(uint code) { if (code != 0) throw new Win32Exception((int)code, "The Windows lid-setting API failed (" + code + ")."); }
    public static Guid ActiveScheme()
    {
        IntPtr pointer; Check(PowerGetActiveScheme(IntPtr.Zero, out pointer));
        try { return Marshal.PtrToStructure<Guid>(pointer); } finally { LocalFree(pointer); }
    }
    public static AgentsOnWin11LidValues Read(Guid scheme)
    {
        var group = Buttons; var setting = Lid; uint ac, dc;
        Check(PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref group, ref setting, out ac));
        Check(PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref group, ref setting, out dc));
        return new AgentsOnWin11LidValues { Scheme = scheme, Ac = ac, Dc = dc };
    }
    public static void Write(Guid scheme, uint ac, uint dc)
    {
        var group = Buttons; var setting = Lid;
        Check(PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref group, ref setting, ac));
        Check(PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref group, ref setting, dc));
        if (ActiveScheme() == scheme) Check(PowerSetActiveScheme(IntPtr.Zero, ref scheme));
    }
}
'@

    New-Item -ItemType Directory -Path $work | Out-Null
    $archiveName = "Agents-On-Windows-$Runtime.zip"
    $archive = Join-Path $work $archiveName
    Download-Asset $archiveName $archive
    Download-Asset "$archiveName.sha256" "$archive.sha256"
    $checksum = [IO.File]::ReadAllText("$archive.sha256").Trim()
    Assert-True ($checksum -match '^([a-fA-F0-9]{64})\s+\*?([^\r\n]+)$') 'The published ZIP checksum file is invalid.'
    $expectedHash = $Matches[1]
    Assert-True ($Matches[2] -ceq $archiveName) 'The published checksum names another ZIP.'
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($actualHash -eq $expectedHash.ToLowerInvariant()) 'The published ZIP checksum did not match.'
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            Assert-True ($name.StartsWith('Agents-On-Windows/') -and $name -notmatch '(^|/)\.\.(/|$)|:' -and -not $name.StartsWith('/')) 'Unsafe published archive entry.'
            if ($entry.Name.Length -gt 0) { Assert-True ($seen.Add($name)) 'The published archive contains duplicate filenames.' }
        }
    } finally { $zip.Dispose() }
    $expanded = Join-Path $work 'expanded'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $package = Join-Path $expanded 'Agents-On-Windows'
    $manifest = Join-Path $package 'FILES.sha256'
    $listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        Assert-True ($line -match '^([a-fA-F0-9]{64})  (.+)$') 'Invalid published file manifest.'
        $hash = $Matches[1]; $relative = $Matches[2]
        Assert-True (-not [IO.Path]::IsPathRooted($relative) -and $relative -notmatch '(^|[\\/])\.\.([\\/]|$)|:') 'Unsafe manifest file path.'
        Assert-True ($listed.Add($relative)) 'Duplicate published manifest entry.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $package $relative) -Algorithm SHA256).Hash -ieq $hash) "Published package verification failed: $relative"
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $package -File -Recurse | Where-Object { $_.FullName -ine $manifest })
    Assert-True ($actualFiles.Count -eq $listed.Count) 'The published package contains unlisted files.'
    foreach ($file in $actualFiles) {
        Assert-True ($listed.Contains($file.FullName.Substring($package.Length + 1).Replace('\', '/'))) 'The published package contains an unlisted file.'
    }
    foreach ($required in @('AgentsOn.exe', 'install.ps1', 'uninstall.ps1')) { Assert-True ($listed.Contains($required)) "The published package lacks $required." }
    $binary = Join-Path $package 'AgentsOn.exe'
    $ownedPaths.Add($binary); $ownedPaths.Add($installed)
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($binary))
    try {
        Assert-True ($reader.ReadUInt16() -eq 0x5A4D) 'The published executable lacks an MZ header.'
        $reader.BaseStream.Position = 0x3C; $pe = $reader.ReadUInt32()
        $reader.BaseStream.Position = $pe
        Assert-True ($reader.ReadUInt32() -eq 0x00004550) 'The published executable lacks a PE header.'
        $machine = $reader.ReadUInt16()
        $expectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
        Assert-True ($machine -eq $expectedMachine) 'The published executable has the wrong architecture.'
    } finally { $reader.Dispose() }
    $evidence.assets = [ordered]@{ zip = $archiveName; sha256 = $actualHash; peMachine = ('0x{0:X4}' -f $machine) }
    Record-Step 'published-package-integrity' 'passed' $evidence.assets
    Invoke-App $binary '--self-test' 90 | Out-Null
    Record-Step 'published-native-self-test' 'passed' ([ordered]@{ execution = $(if ($Runtime -eq 'win-arm64') { 'native ARM64' } else { 'x64 emulation on ARM64' }) })

    $packageInstaller = Join-Path $package 'install.ps1'
    $installationStarted = $true
    & $packageInstaller -ArchivePath $archive -DesktopShortcut
    $status = App-Status $installed
    Assert-True (-not $status.active -and $status.label -eq 'agents off') 'The installed published app did not start off.'
    $startup = (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On').'Agents On'
    Assert-True ($startup -eq ('"' + $installed + '"')) 'Login startup points to the wrong executable.'
    Record-Step 'published-install-and-starts-off' 'passed' $status
    $owners = @(Owned-Processes $installed)
    Assert-True ($owners.Count -eq 1) 'The initial tray owner could not be identified unambiguously.'
    $uiProcessId = [int]$owners[0].ProcessId

    try {
        $originalPower = [AgentsOnWin11Power]::Read([AgentsOnWin11Power]::ActiveScheme())
        $evidence.originalPower = Power-Record $originalPower
        $powerTouched = $true
        [AgentsOnWin11Power]::Write($originalPower.Scheme, 1, 1)
        Wait-Power 1 1 | Out-Null
    } catch {
        $lidUnavailable = $_.Exception.Message
        Record-Step 'lid-policy-api' 'unavailable' $lidUnavailable
    }
    if ($null -eq $lidUnavailable) {
        $on = (Invoke-App $installed '--on') | ConvertFrom-Json
        Assert-True ($on.ok -and $on.active -and $on.label -eq 'agents on') 'The published app did not turn on.'
        $onPower = Wait-Power 0 0
        $off = (Invoke-App $installed '--off') | ConvertFrom-Json
        Assert-True ($off.ok -and -not $off.active -and $off.label -eq 'agents off') 'The published app did not turn off.'
        $offPower = Wait-Power 1 1 $true
        Record-Step 'published-on-off-lid-restoration' 'passed' ([ordered]@{ on = (Power-Record $onPower); off = (Power-Record $offPower) })

        $again = (Invoke-App $installed '--on') | ConvertFrom-Json
        Assert-True ($again.ok -and $again.active) 'The published crash-recovery session did not start.'
        Wait-Power 0 0 | Out-Null
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $uiProcessId" -OperationTimeoutSec 5
        Assert-True ($null -ne $owner -and $owner.ExecutablePath -ieq $installed) 'The original tray owner changed before the controlled crash test.'
        Stop-Process -Id $uiProcessId -Force
        Wait-Power 1 1 $true | Out-Null
        Wait-OwnedExit $installed
        Record-Step 'published-watchdog-crash-restoration' 'passed' ([ordered]@{ terminatedUiProcess = $uiProcessId; restored = '1/1'; recoveryJournalRemoved = $true })
    }
    & $packageInstaller -ArchivePath $archive -SkipStartup
    $upgraded = App-Status $installed
    Assert-True (-not $upgraded.active) 'The upgraded published app did not start off.'
    Assert-True ($null -eq (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue)) 'SkipStartup did not remove the login entry.'
    Record-Step 'published-upgrade-and-skip-startup' 'passed' $upgraded
    & (Join-Path $installedRoot 'uninstall.ps1')
    Wait-OwnedExit $installed
    Assert-True (-not (Test-Path -LiteralPath $installed) -and $null -eq (Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue)) 'Published uninstall left the app or startup entry behind.'
    Record-Step 'published-uninstall' 'passed'
    if ($null -ne $lidUnavailable) { throw 'Published UI/install tests completed, but lid-policy integration was unavailable; see evidence.json.' }
} catch {
    $failure = $_.Exception.Message
    $evidence.errors += $failure
} finally {
    $allStopped = $true
    foreach ($path in $ownedPaths) {
        try {
            if (@(Owned-Processes $path).Count -gt 0 -and (Test-Path -LiteralPath $path)) { Invoke-App $path '--quit' | Out-Null }
            Wait-OwnedExit $path
        } catch {
            $allStopped = $false
            $evidence.errors += "Owned process cleanup: $($_.Exception.Message)"
        }
    }
    if ($installationStarted -and (Test-Path -LiteralPath (Join-Path $installedRoot 'uninstall.ps1')) -and $allStopped) {
        try { & (Join-Path $installedRoot 'uninstall.ps1') }
        catch { $evidence.errors += "Uninstall cleanup: $($_.Exception.Message)" }
    }
    if ($powerTouched -and $null -ne $originalPower) {
        if ($allStopped) {
            try {
                [AgentsOnWin11Power]::Write($originalPower.Scheme, $originalPower.Ac, $originalPower.Dc)
                $restored = [AgentsOnWin11Power]::Read($originalPower.Scheme)
                Assert-True ($restored.Ac -eq $originalPower.Ac -and $restored.Dc -eq $originalPower.Dc) 'Original lid values did not restore.'
                $evidence.restoredPower = Power-Record $restored
                Record-Step 'original-lid-values-restored' 'passed' $evidence.restoredPower
            } catch { $evidence.errors += "Original power restore: $($_.Exception.Message)" }
        } else { $evidence.errors += 'Original power restore was withheld because a fixture-owned recovery process is still running.' }
    }
    if ($allStopped -and (Test-Path -LiteralPath $work)) {
        try { Remove-Item -LiteralPath $work -Recurse -Force }
        catch { $evidence.errors += "Temporary package cleanup: $($_.Exception.Message)" }
    }
    $evidence.status = if ($evidence.errors.Count -eq 0) { 'passed' } else { 'failed' }
    $evidence.completedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $reportRoot 'evidence.json'), ($evidence | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
if ($evidence.status -ne 'passed') { throw ($evidence.errors -join '; ') }
Write-Host "Published Agents On $Version verified on Windows 11 ($Runtime); original power values restored."
