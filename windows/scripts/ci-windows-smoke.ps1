[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$releaseDirectory = Join-Path (Get-Location) "release"
$setup = Get-ChildItem $releaseDirectory -File -Filter "*.exe" |
  Where-Object Name -Like "*Setup*.exe" |
  Select-Object -First 1

if (-not $setup) {
  throw "NSIS installer is missing"
}

function Stop-TokenRemain {
  Get-Process -Name "TokenRemain*" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

function Assert-NoTokenRemainErrorWindow {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]] $Processes,
    [Parameter(Mandatory = $true)]
    [string] $Label
  )

  $errorWindows = @($Processes | Where-Object {
    $_.MainWindowTitle -match "(?i)error|javascript"
  })
  if ($errorWindows.Count -gt 0) {
    $titles = ($errorWindows | ForEach-Object MainWindowTitle) -join ", "
    throw "$Label opened an error window instead of the app: $titles"
  }
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
    $running = @(Get-Process -Name "TokenRemain*" -ErrorAction SilentlyContinue)
    Assert-NoTokenRemainErrorWindow -Processes $running -Label $Label
    $visibleApp = @($running | Where-Object {
      $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq "TokenRemain"
    })
    if ($visibleApp.Count -gt 0) {
      Write-Host "$Label displayed its TokenRemain window with $($running.Count) process(es)"
      $stabilityDeadline = (Get-Date).AddSeconds(5)
      do {
        Start-Sleep -Milliseconds 500
        $stillRunning = @(Get-Process -Name "TokenRemain*" -ErrorAction SilentlyContinue)
        Assert-NoTokenRemainErrorWindow -Processes $stillRunning -Label $Label
        $stillVisible = @($stillRunning | Where-Object {
          $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq "TokenRemain"
        })
        if ($stillVisible.Count -eq 0) {
          throw "$Label lost its TokenRemain window during the stability window"
        }
      } while ((Get-Date) -lt $stabilityDeadline)
      if ($stillRunning.Count -eq 0) {
        throw "$Label exited during the stability window"
      }
      return
    }

    if ($launched.HasExited -and $running.Count -eq 0) {
      throw "$Label exited before TokenRemain started (exit code $($launched.ExitCode))"
    }
  } while ((Get-Date) -lt $deadline)

  throw "$Label did not display its TokenRemain window within 20 seconds"
}

$installDirectory = Join-Path $env:RUNNER_TEMP "TokenRemain-install-$env:RUNNER_ARCH"
$installer = Start-Process -FilePath $setup.FullName `
  -ArgumentList @("/S", "/D=$installDirectory") `
  -Wait `
  -PassThru
if ($installer.ExitCode -ne 0) {
  throw "NSIS installer failed with exit code $($installer.ExitCode)"
}

$installedExecutableCandidates = @(
  (Join-Path $installDirectory "TokenRemain.exe"),
  (Join-Path $env:LOCALAPPDATA "Programs\TokenRemain\TokenRemain.exe"),
  (Join-Path $env:LOCALAPPDATA "TokenRemain\TokenRemain.exe"),
  (Join-Path $env:ProgramFiles "TokenRemain\TokenRemain.exe")
)
$installedExecutable = $installedExecutableCandidates |
  Where-Object { Test-Path $_ -PathType Leaf } |
  Select-Object -First 1
if (-not $installedExecutable) {
  throw "Installed TokenRemain.exe was not found at any expected NSIS location: $($installedExecutableCandidates -join ', ')"
}
$installDirectory = Split-Path $installedExecutable -Parent
Write-Host "TokenRemain installed at $installDirectory"

$versionInfo = (Get-Item $installedExecutable).VersionInfo
if ($versionInfo.FileDescription -ne "TokenRemain") {
  throw "Installed executable FileDescription is '$($versionInfo.FileDescription)', expected 'TokenRemain'"
}
if ($versionInfo.ProductName -ne "TokenRemain") {
  throw "Installed executable ProductName is '$($versionInfo.ProductName)', expected 'TokenRemain'"
}
Write-Host "Installed executable branding is TokenRemain"

$ccusageArchitecture = switch ($env:RUNNER_ARCH) {
  "X64" { "x64" }
  "ARM64" { "arm64" }
  default { throw "Unsupported Windows runner architecture: $env:RUNNER_ARCH" }
}
$ccusageExecutable = Join-Path $installDirectory `
  "resources\app.asar.unpacked\node_modules\@ccusage\ccusage-win32-$ccusageArchitecture\bin\ccusage.exe"
if (-not (Test-Path $ccusageExecutable -PathType Leaf)) {
  throw "Bundled ccusage helper was not found at $ccusageExecutable"
}
$ccusageCheck = Start-Process -FilePath $ccusageExecutable `
  -ArgumentList "--version" `
  -NoNewWindow `
  -Wait `
  -PassThru
if ($ccusageCheck.ExitCode -ne 0) {
  throw "Bundled ccusage helper failed to start (exit code $($ccusageCheck.ExitCode))"
}
Write-Host "Bundled ccusage helper starts on $env:RUNNER_ARCH"

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
Write-Host "NSIS install, ccusage helper, app launch, and uninstall smoke test passed"
