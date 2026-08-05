[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$releaseDirectory = Join-Path (Get-Location) "release"
$setup = Get-ChildItem $releaseDirectory -File -Filter "*.exe" |
  Where-Object Name -Like "*Setup*.exe" |
  Select-Object -First 1
$portable = Get-ChildItem $releaseDirectory -File -Filter "*.exe" |
  Where-Object Name -NotLike "*Setup*.exe" |
  Select-Object -First 1

if (-not $setup) {
  throw "NSIS installer is missing"
}
if (-not $portable) {
  throw "Portable executable is missing"
}

function Stop-TokenRemain {
  Get-Process -Name "TokenRemain" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

function Assert-TokenRemainStarts {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Executable,
    [Parameter(Mandatory = $true)]
    [string] $Label
  )

  Stop-TokenRemain
  $launched = Start-Process -FilePath $Executable -PassThru
  $deadline = (Get-Date).AddSeconds(20)

  do {
    Start-Sleep -Milliseconds 500
    $running = @(Get-Process -Name "TokenRemain" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
      Write-Host "$Label started with $($running.Count) TokenRemain process(es)"
      Start-Sleep -Seconds 5
      $stillRunning = @(Get-Process -Name "TokenRemain" -ErrorAction SilentlyContinue)
      if ($stillRunning.Count -eq 0) {
        throw "$Label exited during the stability window"
      }
      return
    }

    if ($launched.HasExited -and (Get-Date) -ge $deadline.AddSeconds(-15)) {
      throw "$Label exited before TokenRemain started (exit code $($launched.ExitCode))"
    }
  } while ((Get-Date) -lt $deadline)

  throw "$Label did not start within 20 seconds"
}

$installDirectory = Join-Path $env:RUNNER_TEMP "TokenRemain-install-$env:RUNNER_ARCH"
$installer = Start-Process -FilePath $setup.FullName `
  -ArgumentList @("/S", "/D=$installDirectory") `
  -Wait `
  -PassThru
if ($installer.ExitCode -ne 0) {
  throw "NSIS installer failed with exit code $($installer.ExitCode)"
}

$installedExecutable = Join-Path $installDirectory "TokenRemain.exe"
if (-not (Test-Path $installedExecutable -PathType Leaf)) {
  throw "Installed TokenRemain.exe was not found at $installedExecutable"
}
Assert-TokenRemainStarts -Executable $installedExecutable -Label "Installed app"
Stop-TokenRemain

$uninstaller = Get-ChildItem $installDirectory -File -Filter "Uninstall*.exe" |
  Select-Object -First 1
if (-not $uninstaller) {
  throw "NSIS uninstaller is missing"
}
$uninstall = Start-Process -FilePath $uninstaller.FullName `
  -ArgumentList "/S" `
  -Wait `
  -PassThru
if ($uninstall.ExitCode -ne 0) {
  throw "NSIS uninstaller failed with exit code $($uninstall.ExitCode)"
}

$uninstallDeadline = (Get-Date).AddSeconds(20)
while ((Test-Path $installedExecutable) -and (Get-Date) -lt $uninstallDeadline) {
  Start-Sleep -Milliseconds 500
}
if (Test-Path $installedExecutable) {
  throw "Installed executable remained after uninstall"
}
Write-Host "NSIS install, launch, and uninstall smoke test passed"

Assert-TokenRemainStarts -Executable $portable.FullName -Label "Portable app"
Stop-TokenRemain
Write-Host "Portable launch smoke test passed"
