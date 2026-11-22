[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Directory-sharing regression checks require Windows.' }

# Load the actual installer function without executing installation or touching app settings.
$installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows/install.ps1'
$tokens = $null
$errors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }
$moveFunction = @($tree.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Move-AppDirectory'
}, $true))
if ($moveFunction.Count -ne 1) { throw 'The installer must define one Move-AppDirectory function.' }
. ([scriptblock]::Create($moveFunction[0].Extent.Text))

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;
public static class AgentsOnDirectoryLockFixture
{
    // Read access participates in Windows sharing checks; metadata-only access does not.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    public static SafeFileHandle Lock(string path)
    {
        var handle = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
        return handle;
    }
    public static void VerifyRenameIsLocked(string source, string destination)
    {
        try { Directory.Move(source, destination); }
        catch (IOException error) when ((error.HResult & 0xFFFF) == 32) { return; }
        catch (UnauthorizedAccessException) { return; }
        throw new Exception("The native fixture did not establish a rename-blocking directory handle.");
    }
    public static Timer ReleaseDuringBackoff(SafeFileHandle handle)
    {
        return new Timer(_ => handle.Dispose(), null, 100, Timeout.Infinite);
    }
}
'@

$script:backoffs = 0
$script:releaseOnBackoff = $null
$script:releaseTimer = $null
# Observe retries while retaining the production delay and real filesystem operations.
function Start-Sleep([int]$Milliseconds) {
    $script:backoffs++
    if ($null -ne $script:releaseOnBackoff) {
        $script:releaseTimer = [AgentsOnDirectoryLockFixture]::ReleaseDuringBackoff($script:releaseOnBackoff)
        $script:releaseOnBackoff = $null
    }
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function New-Source([string]$Path) {
    New-Item -ItemType Directory -Path $Path | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'app.txt'), 'original package')
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('agents-on-move-check-' + [guid]::NewGuid().ToString('N'))
$locked = $null
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $source = Join-Path $work 'transient-source'
    $destination = Join-Path $work 'transient-destination'
    New-Source $source
    $locked = [AgentsOnDirectoryLockFixture]::Lock($source)
    [AgentsOnDirectoryLockFixture]::VerifyRenameIsLocked($source, $destination)
    $script:releaseOnBackoff = $locked
    Move-AppDirectory $source $destination
    Assert-True ($script:backoffs -gt 0) 'The temporary lock did not exercise a retry.'
    Assert-True (-not (Test-Path -LiteralPath $source)) 'The recovered move left the source behind.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'app.txt')) -eq 'original package') 'The recovered move lost package contents.'
    $script:releaseTimer.Dispose()
    $script:releaseTimer = $null
    $locked.Dispose()
    $locked = $null
    Write-Host 'A real directory lock released during backoff was retried successfully.'

    $source = Join-Path $work 'persistent-source'
    $destination = Join-Path $work 'persistent-destination'
    New-Source $source
    $locked = [AgentsOnDirectoryLockFixture]::Lock($source)
    [AgentsOnDirectoryLockFixture]::VerifyRenameIsLocked($source, $destination)
    $script:backoffs = 0
    $failed = $false
    try { Move-AppDirectory $source $destination } catch { $failed = $true }
    Assert-True $failed 'A persistently locked directory was moved.'
    Assert-True ($script:backoffs -eq 19) 'A persistent lock did not exhaust the bounded 20 attempts.'
    Assert-True (Test-Path -LiteralPath $source -PathType Container) 'Retry exhaustion removed the source directory.'
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Retry exhaustion created a partial destination.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $source 'app.txt')) -eq 'original package') 'Retry exhaustion changed the source package.'
    $locked.Dispose()
    $locked = $null
    Write-Host 'A persistent real lock exhausted 20 attempts and retained the source.'

    $source = Join-Path $work 'unrelated-source'
    $destination = Join-Path $work 'existing-destination'
    New-Source $source
    New-Item -ItemType Directory -Path $destination | Out-Null
    [IO.File]::WriteAllText((Join-Path $destination 'existing.txt'), 'leave me intact')
    $script:backoffs = 0
    $failed = $false
    try { Move-AppDirectory $source $destination } catch { $failed = $true }
    Assert-True $failed 'An existing destination was overwritten or merged.'
    Assert-True ($script:backoffs -eq 0) 'An unrelated destination-exists error was retried.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $source 'app.txt')) -eq 'original package') 'An unrelated failure changed the source.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'existing.txt')) -eq 'leave me intact') 'An unrelated failure changed the destination.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $destination 'app.txt'))) 'An unrelated failure merged source files into the destination.'
    Write-Host 'An unrelated destination-exists error failed immediately without changing either folder.'
} finally {
    if ($null -ne $script:releaseTimer) { $script:releaseTimer.Dispose() }
    if ($null -ne $locked) { $locked.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
