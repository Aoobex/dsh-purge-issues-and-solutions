param(
  [string]$ExePath = '',
  [switch]$Force
)

# 回滚：把 app.asar.purge-manual-*.bak 改回 app.asar（DSH 必须已完全退出）

$ErrorActionPreference = 'Stop'
function Info($t) { Write-Host ('  ' + $t) }
function Ok($t)   { Write-Host ('  [OK]   ' + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ('  [WARN] ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('  [FAIL] ' + $t) -ForegroundColor Red }

function Resolve-Exe([string]$given) {
  if ($given) { return (Get-Item -LiteralPath $given).FullName }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  if ($candidates.Count -ge 1) { return (Get-Item -LiteralPath $candidates[0]).FullName }
  throw '找不到 DSH 安装，请用 -ExePath 指定。'
}

$exe = Resolve-Exe $ExePath
$res = Join-Path (Split-Path -Parent $exe) 'resources'
$asar = Join-Path $res 'app.asar'

$procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -and [string]::Equals($_.Path, $exe, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
if ($procs.Count -and -not $Force) {
  Bad ("DSH 仍在运行（" + $procs.Count + " 个进程）。请先从托盘完整退出。")
  exit 1
}

if (Test-Path -LiteralPath $asar) {
  Bad 'app.asar 已存在，无需回滚（如需覆盖请人工确认后手动处理）'
  exit 0
}

$baks = @(Get-ChildItem -LiteralPath $res -Filter 'app.asar.purge-*.bak' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if (-not $baks.Count) { Bad '没有找到 app.asar.purge-*.bak 备份'; exit 1 }

$pick = $baks[0]
Info ("使用备份：" + $pick.FullName)
$hBefore = (Get-FileHash -LiteralPath $pick.FullName -Algorithm SHA256).Hash
Info "备份 sha256 = $hBefore"

$statePath = $asar + '.purge-handoff.json'
if (Test-Path -LiteralPath $statePath) {
  try {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($st.archive_sha256) {
      if ($st.archive_sha256 -eq $hBefore) { Ok '与状态文件记录的原始哈希一致' }
      else { Warn ("状态记录哈希不一致：state=" + $st.archive_sha256 + " 备份=" + $hBefore) }
    }
  } catch { }
}

Move-Item -LiteralPath $pick.FullName -Destination $asar
if (-not (Test-Path -LiteralPath $asar)) { Bad '回滚失败'; exit 1 }
$hAfter = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
if ($hAfter -ne $hBefore) { Bad '回滚后哈希不一致，请人工核对'; exit 1 }

Ok "已恢复：$asar"
Ok "现在可以手动打开 DSH（将重新从 app.asar 加载官方归档）"
Info '提示：此时磁盘补丁仍在 resources\app 里，但不会再被加载。'
