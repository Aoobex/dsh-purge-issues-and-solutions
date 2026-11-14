param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [Parameter(Mandatory=$true)][string]$AsarPath,
  [Parameter(Mandatory=$true)][string]$StatePath,
  [Parameter(Mandatory=$true)][string]$Token,
  [int]$TimeoutSeconds = 3600,
  [int]$PollMilliseconds = 500
)

# dsh-purge asar handoff helper (scheduled-task flavour)
# Waits for every process of this exact exe path to exit, then renames
# app.asar aside as app.asar.purge-manual-<token>.bak and verifies SHA256.
# It never kills a process, never starts DSH and never deletes the archive.

$ErrorActionPreference = 'Stop'
$log          = $StatePath + '.log'
$backup       = $AsarPath + '.purge-manual-' + $Token + '.bak'
$expectedHash = ''

function Archive-Hash([string]$file) {
  $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
  finally { $sha.Dispose(); $stream.Dispose() }
}

function Save-State([string]$phase, [string]$detail = '') {
  $state = [ordered]@{
    token          = $Token
    pid            = $PID
    phase          = $phase
    updated_at     = [DateTime]::UtcNow.ToString('o')
    detail         = $detail
    backup         = $backup
    archive_sha256 = $expectedHash
    mode           = 'scheduled-task-recovery'
  }
  $json = $state | ConvertTo-Json -Compress
  $tmp  = $StatePath + '.' + $Token + '.tmp'
  [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $StatePath -Force
  Add-Content -LiteralPath $log -Value (([DateTime]::UtcNow.ToString('o')) + ' ' + $phase + ' ' + $detail) -Encoding UTF8
}

try {
  Save-State 'ready' ('helper pid=' + $PID)

  $resDir = Split-Path -Parent $AsarPath
  $appDir = Join-Path $resDir 'app'
  if (-not (Test-Path -LiteralPath (Join-Path $appDir 'package.json'))) {
    throw 'Unpacked app/package.json is missing; original archive retained.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $appDir 'lib\main.js'))) {
    throw 'Unpacked app/lib/main.js is missing; original archive retained.'
  }
  $runtimeEntry = 'runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
  if ((Test-Path -LiteralPath (Join-Path $resDir $runtimeEntry)) -and
      -not (Test-Path -LiteralPath (Join-Path $appDir $runtimeEntry))) {
    throw 'Unpacked app/runtime is unavailable; repair the runtime link before handoff. Original archive retained.'
  }

  if (Test-Path -LiteralPath $AsarPath) {
    $expectedHash = Archive-Hash $AsarPath
  } else {
    Save-State 'already_unsealed' 'archive already absent; nothing to move'
    exit 0
  }

  Save-State 'waiting_for_quit' ('waiting for all ' + $ExePath + ' processes to exit')

  $deadline    = (Get-Date).AddSeconds($TimeoutSeconds)
  $processName = [IO.Path]::GetFileNameWithoutExtension($ExePath)
  while ((Get-Date) -lt $deadline) {
    $alive = @(Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object {
      try { $_.Path -and [string]::Equals($_.Path, $ExePath, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
    if ($alive.Count -gt 0) { Start-Sleep -Milliseconds $PollMilliseconds; continue }

    if (-not (Test-Path -LiteralPath $AsarPath)) {
      Save-State 'already_unsealed' 'archive already absent; nothing to move'
      exit 0
    }
    if ((Archive-Hash $AsarPath) -ne $expectedHash) {
      throw 'Archive changed while waiting (official update?); original retained. Re-apply patches to the new version first.'
    }

    Save-State 'moving' 'renaming archive aside'
    try {
      Move-Item -LiteralPath $AsarPath -Destination $backup -ErrorAction Stop
    } catch {
      $code = $null
      try { $code = [int]$_.Exception.HResult -band 65535 } catch { }
      if ($code -in @(32, 33)) {
        Save-State 'waiting_for_unlock' $_.Exception.Message
        Start-Sleep -Milliseconds $PollMilliseconds
        continue
      }
      throw
    }

    if ((Test-Path -LiteralPath $AsarPath) -or -not (Test-Path -LiteralPath $backup)) {
      throw 'Archive move verification failed.'
    }
    if ((Archive-Hash $backup) -ne $expectedHash) {
      throw 'Backup hash verification failed; do not open DSH until recovered.'
    }

    Save-State 'complete' ('Archive preserved as ' + $backup + '. Open DSH manually to load disk patches.')
    exit 0
  }

  Save-State 'expired' 'Timed out; original archive retained. Run 3-schedule-swap.ps1 again after a full quit.'
  exit 2
} catch {
  try { Save-State 'failed' $_.Exception.Message } catch { }
  exit 1
}
