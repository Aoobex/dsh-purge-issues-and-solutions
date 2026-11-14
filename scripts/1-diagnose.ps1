param(
  [string]$ExePath = '',
  [switch]$SkipProbe
)

# dsh-purge 换包失败 —— 只读诊断
# 不修改任何文件，不结束任何进程，不启停 DSH。

$ErrorActionPreference = 'Continue'
function Line($t) { Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }
function Ok($t)   { Write-Host ('  [OK]   ' + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ('  [WARN] ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('  [FAIL] ' + $t) -ForegroundColor Red }
function Info($t) { Write-Host ('         ' + $t) }

function Resolve-Exe([string]$given) {
  if ($given) {
    if (-not (Test-Path -LiteralPath $given)) { throw "指定的 ExePath 不存在: $given" }
    return (Get-Item -LiteralPath $given).FullName
  }
  $running = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.Path } |
    Select-Object -ExpandProperty Path -Unique)
  if ($running.Count -ge 1) { return $running[0] }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  if ($candidates.Count -ge 1) { return (Get-Item -LiteralPath $candidates[0]).FullName }
  throw '找不到 DSH 桌面安装，请用 -ExePath 指定 DeepSeek Harness.exe 的完整路径。'
}

try { $exe = Resolve-Exe $ExePath } catch { Bad $_.Exception.Message; exit 1 }

$res        = Join-Path (Split-Path -Parent $exe) 'resources'
$asar       = Join-Path $res 'app.asar'
$appDir     = Join-Path $res 'app'
$statePath  = $asar + '.purge-handoff.json'
$stateLog   = $statePath + '.log'
$brokerLog  = $statePath + '.broker.log'
$renameLock = $asar + '.rename-pending'

Line '安装与路径'
Info "exe      = $exe"
Info "resources= $res"
Info "asar     = $asar"
Info "app dir  = $appDir"

Line '运行中的进程'
$procs = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -and [string]::Equals($_.Path, $exe, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
if ($procs.Count) { Info ("该安装路径进程数: " + $procs.Count + "  pid=" + (($procs.Id) -join ',')) }
else { Info '该安装路径当前没有进程（DSH 未运行）' }

Line '归档与解包目录'
if (Test-Path -LiteralPath $asar) {
  $h = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
  $len = (Get-Item -LiteralPath $asar).Length
  Warn "app.asar 仍在磁盘（$len 字节）→ Electron 会优先加载它，磁盘补丁不会生效"
  Info "sha256 = $h"
} else {
  Ok 'app.asar 不存在 → 已解封，Electron 会加载 resources\app'
}
$appPkg = Join-Path $appDir 'package.json'
$appMain = Join-Path $appDir 'lib\main.js'
if (Test-Path -LiteralPath $appPkg) {
  try { $v = (Get-Content -LiteralPath $appPkg -Raw | ConvertFrom-Json).version; Ok "resources\app\package.json 存在（version=$v）" }
  catch { Warn 'resources\app\package.json 存在但无法解析' }
} else { Bad 'resources\app\package.json 缺失 → 不能换包（会保留原归档）' }
if (Test-Path -LiteralPath $appMain) { Ok 'resources\app\lib\main.js 存在' } else { Bad 'resources\app\lib\main.js 缺失' }
$rt = Join-Path $appDir 'runtime'
if (Test-Path -LiteralPath $rt) {
  $r = Get-Item -LiteralPath $rt -Force
  $tgt = @($r.Target)[0]
  $okRt = $tgt -and (Test-Path -LiteralPath (Join-Path $rt 'primary-runtime\dependencies\pnpm\bin\pnpm.mjs'))
  if ($okRt) { Ok "app\runtime 链接可用（$($r.LinkType) → $tgt）" } else { Bad "app\runtime 链接异常（target=$tgt）" }
} else { Info 'app\runtime 不存在（部分版本无此项，可忽略）' }
$bak = @(Get-ChildItem -LiteralPath $res -Filter 'app.asar.purge-*.bak' -ErrorAction SilentlyContinue)
if ($bak.Count) { Info ("已有归档备份: " + (($bak | ForEach-Object { $_.Name }) -join ', ')) } else { Info '暂无归档备份' }

Line '换包握手状态'
if (Test-Path -LiteralPath $statePath) {
  try {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Info ("phase=" + $st.phase + "  token=" + $st.token + "  pid=" + $st.pid + "  updated_at=" + $st.updated_at)
    if ($st.detail) { Info ("detail=" + $st.detail) }
    if ($st.pid) {
      $alive = [bool](Get-Process -Id $st.pid -ErrorAction SilentlyContinue)
      if ($alive) { Ok '记录的助手进程仍在运行' } else { Info '记录的助手进程已不在' }
    }
    switch ([string]$st.phase) {
      'complete'        { Ok '换包已完成（归档已改名保留）' }
      'waiting_for_quit'{ Ok '助手正在等 DSH 完全退出（正常中间态）' }
      'failed'          { Bad '上次换包失败（对照 .broker.log 判断是引号缺陷还是被安全软件拦截）' }
      'expired'         { Warn '助手等待超时，未改名；可重新安排' }
      default           { Info '见上方 phase' }
    }
  } catch { Warn '状态文件无法解析' }
} else { Info '状态文件不存在（从未安排过换包）' }

if (Test-Path -LiteralPath $stateLog) {
  Info '-- .json.log 尾部 --'
  Get-Content -LiteralPath $stateLog -Tail 5 | ForEach-Object { Info $_ }
} else { Warn '.json.log 不存在 → 助手脚本从未执行过（本问题的典型证据）' }

if (Test-Path -LiteralPath $brokerLog) {
  Info '-- .broker.log 尾部（UTF-8 混排 CLIXML）--'
  $bytes = [IO.File]::ReadAllBytes($brokerLog)
  $text = [Text.Encoding]::UTF8.GetString($bytes)
  ($text -split "`r?`n") | Where-Object { $_ -match 'token=|Helper pid .*no longer observable|Local WMI handoff creation failed' -and $_ -notmatch '^<Objs' } |
    Select-Object -Last 6 | ForEach-Object { if ($_.Length -gt 150) { Info ($_.Substring(0, 150) + ' …') } else { Info $_ } }
} else { Info '.broker.log 不存在' }

if (Test-Path -LiteralPath $renameLock) {
  $lockToken = (Get-Content -LiteralPath $renameLock -Raw).Trim()
  Warn "残留锁 .rename-pending（token=$lockToken）—— 只是失败尝试留下的标记，删它不等于修好"
} else { Info '无 .rename-pending 残留' }

Line '计划任务'
$taskName = 'DSH-Purge-AsarHandoff'
$q = schtasks /query /tn $taskName /fo LIST 2>&1 | Out-String
if ($q -match [regex]::Escape($taskName)) { Info ($q.Trim()) } else { Info '未注册（方案 B 未使用过或已自删）' }

Line '插件文件'
$plugins = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE '.dsh\profiles') -Recurse -Depth 6 -Filter 'windows-asar-handoff.js' -ErrorAction SilentlyContinue)
if (-not $plugins.Count) { Warn '未定位 windows-asar-handoff.js（非 desktop profile 或插件未安装）' }
foreach ($p in $plugins) {
  $content = Get-Content -LiteralPath $p.FullName -Raw
  $ver = ''
  $pkg = Join-Path (Split-Path -Parent (Split-Path -Parent $p.FullName)) 'package.json'
  if ($pkg -and (Test-Path -LiteralPath $pkg)) { $rawPkg = Get-Content -LiteralPath $pkg -Raw; if ($rawPkg -match '"version"\s*:\s*"([^"]+)"') { $ver = $matches[1] } }
  Info ($p.FullName + "  (v$ver)")
  if ($content -match '\$argsRaw') { Ok '  已打引号补丁（WMI 分支使用裸参数）' } else { Warn '  未打引号补丁 → 用 2-patch-plugin.ps1 修补' }
  if ($content -match '\$argsText=\$\{helperArgs\}') { Info '  结构匹配 1.7.x 模板' }
}

if (-not $SkipProbe) {
  Line '环境探测：WMI 派生 PowerShell 是否被拦'
  try {
    $ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 20'))
    $startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
    $startup.ShowWindow = 0
    $r = ([wmiclass]'Win32_Process').Create(('"' + $ps5 + '" -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $enc), $env:TEMP, $startup)
    Start-Sleep -Milliseconds 1500
    $alive = [bool](Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue)
    if ($alive) { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue; Ok 'WMI → PowerShell 可用（插件原路径理论可行）' }
    else { Bad 'WMI → PowerShell 被拦截/秒退（本机装的 HIPS 常见行为）→ 使用方案 B 计划任务' }
  } catch { Warn ('探测失败: ' + $_.Exception.Message) }
}

Line '判定'
if (Test-Path -LiteralPath $asar) {
  $phaseNow = ''
  if (Test-Path -LiteralPath $statePath) {
    try { $phaseNow = [string](Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).phase } catch { }
  }
  if ((Test-Path -LiteralPath $stateLog) -eq $false) {
    Bad '换包失败且助手从未执行 → 与本文档记录的缺陷一致；执行 2-patch-plugin.ps1 + 3-schedule-swap.ps1'
  } elseif ($phaseNow -in @('ready', 'waiting_for_quit', 'waiting_for_unlock')) {
    Ok ('换包已安排（phase=' + $phaseNow + '）：完整退出 DSH 后助手会自动改名，然后手动打开 DSH')
  } elseif ($phaseNow -eq 'failed') {
    Bad '换包失败（助手执行过）→ 看 .json.log 的最后一条错误'
  } elseif ($phaseNow -eq 'expired') {
    Warn '助手等待超时且未改名 → 重跑 3-schedule-swap.ps1，然后尽快完整退出 DSH'
  } else {
    Warn '归档仍密封，状态见上'
  }
} else {
  Ok '已解封：手动打开 DSH 即可从磁盘加载补丁'
}
Write-Host ''
