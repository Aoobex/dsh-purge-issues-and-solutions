param(
  [string]$ExePath = '',
  [int]$TimeoutSeconds = 3600,
  [string]$TaskName = 'DSH-Purge-AsarHandoff',
  [switch]$Force
)

# 方案 B：用「计划任务(SYSTEM) → cmd → 独立 PowerShell 助手」完成换包。
# 绕开被安全软件拦截的 WMI 链路；不结束进程、不重启 DSH、不删除归档。

$ErrorActionPreference = 'Continue'
function Info($t) { Write-Host ("  " + $t) }
function Ok($t)   { Write-Host ("  [OK]   " + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ("  [WARN] " + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ("  [FAIL] " + $t) -ForegroundColor Red }

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
  throw '找不到 DSH 桌面安装，请用 -ExePath 指定。'
}

try { $exe = Resolve-Exe $ExePath } catch { Bad $_.Exception.Message; exit 1 }
$res       = Join-Path (Split-Path -Parent $exe) 'resources'
$asar      = Join-Path $res 'app.asar'
$appDir    = Join-Path $res 'app'
$statePath = $asar + '.purge-handoff.json'

Write-Host '=== 前置检查 ===' -ForegroundColor Cyan
Info "exe   = $exe"
Info "asar  = $asar"

if (-not (Test-Path -LiteralPath (Join-Path $appDir 'package.json'))) { Bad 'resources\app\package.json 缺失 → 拒绝换包（保留原归档）'; exit 1 }
if (-not (Test-Path -LiteralPath (Join-Path $appDir 'lib\main.js'))) { Bad 'resources\app\lib\main.js 缺失 → 拒绝换包'; exit 1 }
Ok 'resources\app 解包目录完整'

if (-not (Test-Path -LiteralPath $asar)) { Ok 'app.asar 已不存在（已解封），无需换包'; exit 0 }
$hashBefore = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
Info "归档 sha256 = $hashBefore"

if ((Test-Path -LiteralPath $statePath) -and -not $Force) {
  try {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($st.phase -in @('ready', 'waiting_for_quit', 'waiting_for_unlock', 'moving', 'starting')) {
      $pidAlive = $false
      if ($st.pid) { $pidAlive = [bool](Get-Process -Id $st.pid -ErrorAction SilentlyContinue) }
      if ($pidAlive -or $st.phase -eq 'ready' -or $st.phase -eq 'waiting_for_quit') {
        Warn "已有一个换包助手在等待：phase=$($st.phase) pid=$($st.pid)"
        Info '直接完整退出 DSH 即可；确需重排请加 -Force'
        exit 0
      }
    }
  } catch { }
}

Write-Host '=== 准备助手 ===' -ForegroundColor Cyan
$stage = Join-Path $env:ProgramData 'dsh-purge-fix'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$helperSrc = Join-Path $PSScriptRoot 'asar-handoff-helper.ps1'
if (-not (Test-Path -LiteralPath $helperSrc)) { Bad "找不到 $helperSrc"; exit 1 }
$helper = Join-Path $stage 'asar-handoff-helper.ps1'
Copy-Item -LiteralPath $helperSrc -Destination $helper -Force

$runner = Join-Path $stage 'run-handoff.cmd'
$runLog = Join-Path $stage 'run-handoff.log'
$token  = [guid]::NewGuid().ToString()
$ps5    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$body = @"
@echo off
set "LOG=$runLog"
echo [%DATE% %TIME%] runner start as %USERNAME% >> "%LOG%"
"$ps5" -NoProfile -ExecutionPolicy Bypass -File "$helper" -ExePath "$exe" -AsarPath "$asar" -StatePath "$statePath" -Token $token -TimeoutSeconds $TimeoutSeconds >> "%LOG%" 2>&1
echo [%DATE% %TIME%] helper exit=%ERRORLEVEL% >> "%LOG%"
schtasks /Delete /TN "$TaskName" /F >nul 2>&1
"@
[IO.File]::WriteAllText($runner, ($body -replace "`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))

Ok "助手已就位：$helper"
Ok "启动包装：$runner"
Ok "token=$token"

Write-Host '=== 注册计划任务 ===' -ForegroundColor Cyan
schtasks /End /TN $TaskName *> $null
schtasks /Delete /TN $TaskName /F *> $null
$stTime = (Get-Date).AddHours(3).ToString('HH:mm')
$create = schtasks /Create /TN $TaskName /TR $runner /SC ONCE /ST $stTime /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-String
$createRc = $LASTEXITCODE
Info $create.Trim()
if ($createRc -ne 0) { Bad '计划任务创建失败（需要管理员权限）'; exit 1 }
$runOut = schtasks /Run /TN $TaskName 2>&1 | Out-String
Info $runOut.Trim()

Write-Host '=== 等待助手回执 ===' -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(30)
$phase = ''
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if (Test-Path -LiteralPath $statePath) {
    try {
      $cur = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
      if ($cur.token -eq $token) { $phase = [string]$cur.phase }
    } catch { }
  }
  if ($phase -in @('waiting_for_quit', 'waiting_for_unlock', 'moving', 'complete', 'already_unsealed', 'failed', 'expired')) { break }
}

switch ($phase) {
  'ready'             { Ok '助手已启动（ready）' }
  'waiting_for_quit'  { Ok '助手已就绪，正在等 DSH 完全退出（waiting_for_quit）' }
  'waiting_for_unlock'{ Warn '助手在等文件解锁（waiting_for_unlock），通常几秒内完成' }
  'moving'            { Ok '助手正在改名（moving）' }
  'complete'          { Ok '换包已完成' }
  'already_unsealed'  { Ok '归档本就不在，无需换包' }
  'failed'            { Bad '助手失败，查看 .json.log 最后一条错误' }
  ''                  { Bad "未收到助手回执；检查 $runLog 与计划任务是否被安全软件拦截"; exit 1 }
  default             { Warn "当前状态：$phase" }
}

Write-Host ''
Write-Host '=== 接下来 ===' -ForegroundColor Cyan
Write-Host '  1) 从托盘完整退出 DSH（只关窗口不算），任务管理器确认该路径的 DeepSeek Harness.exe 全部消失'
Write-Host '  2) 助手会自动把 app.asar 改名为 app.asar.purge-manual-<token>.bak 并校验 SHA256'
Write-Host '  3) 手动重新打开 DSH；用 5-status.ps1 或 purge 面板确认已完成'
Write-Host ''
Write-Host "  状态文件：$statePath"
Write-Host "  握手日志：$statePath.log"
Write-Host "  运行日志：$runLog"
Write-Host ''
