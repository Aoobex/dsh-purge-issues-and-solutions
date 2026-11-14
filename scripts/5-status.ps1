param(
  [string]$ExePath = ''
)

# 查看换包握手状态（只读）

$ErrorActionPreference = 'Continue'
function Info($t) { Write-Host ('  ' + $t) }
function Ok($t)   { Write-Host ('  [OK]   ' + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ('  [WARN] ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('  [FAIL] ' + $t) -ForegroundColor Red }

function Resolve-Exe([string]$given) {
  if ($given) { return (Get-Item -LiteralPath $given).FullName }
  $running = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.Path } |
    Select-Object -ExpandProperty Path -Unique)
  if ($running.Count -ge 1) { return $running[0] }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  if ($candidates.Count -ge 1) { return (Get-Item -LiteralPath $candidates[0]).FullName }
  throw '找不到 DSH 安装，请用 -ExePath 指定。'
}

try { $exe = Resolve-Exe $ExePath } catch { Bad $_.Exception.Message; exit 1 }
$res = Join-Path (Split-Path -Parent $exe) 'resources'
$asar = Join-Path $res 'app.asar'
$statePath = $asar + '.purge-handoff.json'

Write-Host '=== 归档 ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $asar) {
  Warn ('app.asar 仍在（' + (Get-Item -LiteralPath $asar).Length + ' 字节）→ 仍密封')
} else { Ok 'app.asar 已不在 → 已解封，Electron 将加载 resources\app' }
$baks = @(Get-ChildItem -LiteralPath $res -Filter 'app.asar.purge-*.bak' -ErrorAction SilentlyContinue)
foreach ($b in $baks) { Info ('备份：' + $b.Name + '  ' + $b.Length + ' 字节') }

Write-Host '=== 状态文件 ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $statePath) {
  try {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Info ('phase=' + $st.phase + '  pid=' + $st.pid + '  token=' + $st.token)
    Info ('updated_at=' + $st.updated_at)
    if ($st.detail) { Info ('detail=' + $st.detail) }
    if ($st.pid) {
      $alive = [bool](Get-Process -Id $st.pid -ErrorAction SilentlyContinue)
      if ($alive) { Ok '助手进程仍在运行' } else { Warn '助手进程已结束' }
    }
  } catch { Warn '状态文件无法解析' }
} else { Info '无状态文件' }

$stateLog = $statePath + '.log'
if (Test-Path -LiteralPath $stateLog) {
  Write-Host '=== .json.log 尾部 ===' -ForegroundColor Cyan
  Get-Content -LiteralPath $stateLog -Tail 8 | ForEach-Object { Info $_ }
} else { Warn '.json.log 不存在（助手从未执行）' }

Write-Host '=== 计划任务 ===' -ForegroundColor Cyan
$q = schtasks /query /tn 'DSH-Purge-AsarHandoff' /fo LIST /v 2>&1 | Out-String
if ($q -match 'DSH-Purge-AsarHandoff') {
  ($q -split "`r?`n") | Where-Object { $_ -match 'Status|Next Run|Run As User|Task To Run' } | ForEach-Object { Info $_.Trim() }
} else { Info '未注册' }

Write-Host '=== 运行中的 DSH 进程 ===' -ForegroundColor Cyan
$procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -and [string]::Equals($_.Path, $exe, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
Info ("该安装路径进程数：" + $procs.Count)
Write-Host ''
