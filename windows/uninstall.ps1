[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This uninstaller requires Windows.' }
$target = Join-Path $env:LOCALAPPDATA 'Programs\Agents On'
$binary = Join-Path $target 'AgentsOn.exe'
if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "The folder is not a recognized Agents On installation: $target"
}
if (Test-Path -LiteralPath $binary) {
    $process = Start-Process -FilePath $binary -ArgumentList '--quit' -PassThru
    if (-not $process.WaitForExit(15000)) { throw 'Agents On did not stop. Close it before uninstalling.' }
    if ($process.ExitCode -ne 0) { throw 'Agents On could not release its keep-awake request; uninstall cancelled.' }
    $until = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $running = @(Get-Process -Name 'AgentsOn' -ErrorAction SilentlyContinue | Where-Object {
            try { $_.MainModule.FileName -ieq $binary } catch { $false }
        })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    if ($running.Count -ne 0) { throw 'Agents On is still restoring sleep settings. Wait before uninstalling.' }
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startup = Get-ItemProperty -LiteralPath $runKey -Name 'Agents On' -ErrorAction SilentlyContinue
if ($null -ne $startup -and $startup.'Agents On' -eq ('"' + $binary + '"')) {
    Remove-ItemProperty -LiteralPath $runKey -Name 'Agents On'
}
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    $link = Join-Path $folder 'Agents On.lnk'
    if (Test-Path -LiteralPath $link) {
        $shortcut = $shell.CreateShortcut($link)
        if ($shortcut.TargetPath -ieq $binary) { Remove-Item -LiteralPath $link -Force }
    }
}
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
# App settings are deliberately retained unless the app's own settings UI clears them.
Write-Host 'Agents On was removed. Its keep-awake request has been released.'
