param(
  [string[]]$PluginFile = @(),
  [switch]$WhatIf
)

# dsh-purge 1.7.x Windows handoff 引号缺陷修补器（幂等）
# 缺陷：WMI 分支复用 Start-Process 的单引号包装，Win32_Process.Create 收到裸命令行后
#       powershell.exe 把整串开关当成一个参数，脚本零执行、进程秒退。
# 修补：WMI 分支改用未加引号的 $argsRaw；Start-Process 分支的 $argsText 保持原样。

$ErrorActionPreference = 'Stop'
function Info($t) { Write-Host ('  ' + $t) }
function Ok($t)   { Write-Host ('  [OK]   ' + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ('  [WARN] ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('  [FAIL] ' + $t) -ForegroundColor Red }

if (-not $PluginFile.Count) {
  $found = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE '.dsh\profiles') -Recurse -Depth 6 -Filter 'windows-asar-handoff.js' -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty FullName)
  if (-not $found.Count) { Bad '未找到 windows-asar-handoff.js，请用 -PluginFile 指定路径'; exit 1 }
  $PluginFile = $found
}

$oldDecl = "const helperArgs = quote('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + encoded(invoke));"
$newDecl = @'
  const helperCmdLine = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + encoded(invoke);
  // Start-Process -ArgumentList needs one quoted token; Win32_Process.Create takes
  // a raw command line, so the same quoting would make powershell.exe treat the
  // whole switch list as a single positional argument and exit without running.
  const helperArgs = quote(helperCmdLine);
'@ -replace "`r`n", "`n"

$exit = 0
foreach ($file in $PluginFile) {
  Write-Host ''
  Write-Host "=== $file ===" -ForegroundColor Cyan
  if (-not (Test-Path -LiteralPath $file)) { Bad '文件不存在'; $exit = 1; continue }

  $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)

  if ($text -match '\$argsRaw') { Ok '已打过引号补丁，跳过'; continue }

  if ($text -notmatch [regex]::Escape($oldDecl)) {
    Bad '未匹配到 1.7.x 的 helperArgs 声明，版本可能已变化，请人工核对'; $exit = 1; continue
  }
  if ($text -notmatch [regex]::Escape('$argsText=${helperArgs}')) {
    Bad '未匹配到 $argsText=${helperArgs}'; $exit = 1; continue
  }
  if ($text -notmatch [regex]::Escape('$argsText),$env:TEMP,$startup)')) {
    Bad '未匹配到 WMI.Create 调用点'; $exit = 1; continue
  }

  $argsDeclLine = '$argsText=${helperArgs}' + "`n" + '$argsRaw=${quote(helperCmdLine)}'
  $patched = $text.Replace($oldDecl, $newDecl)
  $patched = $patched.Replace('$argsText=${helperArgs}', $argsDeclLine)
  # 只替换 WMI 分支里的调用点；Start-Process 分支用的是 -ArgumentList $argsText，不受影响
  $patched = $patched.Replace(" + `$argsText),`$env:TEMP,`$startup)", " + `$argsRaw),`$env:TEMP,`$startup)")

  if ($patched -eq $text) { Bad '替换未生效'; $exit = 1; continue }

  if ($WhatIf) { Warn 'WhatIf：仅预览，不写盘'; continue }

  $orig = $file + '.orig'
  if (-not (Test-Path -LiteralPath $orig)) {
    Copy-Item -LiteralPath $file -Destination $orig -Force
    Ok "已备份原文件 → $orig"
  } else { Info "原文件备份已存在，保留不动：$orig" }

  [IO.File]::WriteAllText($file, $patched, (New-Object System.Text.UTF8Encoding($false)))
  Ok '补丁已写入'

  # 语法校验（ESM）
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) {
    $tmp = Join-Path $env:TEMP ('handoff-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.mjs')
    Copy-Item -LiteralPath $file -Destination $tmp -Force
    & $node.Source --check $tmp 2>&1 | ForEach-Object { Info $_ }
    if ($LASTEXITCODE -eq 0) { Ok 'node --check 语法通过' } else { Bad '语法检查失败，正在回滚'; Copy-Item -LiteralPath $orig -Destination $file -Force; $exit = 1 }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  } else { Warn '未找到 node，跳过语法检查（建议手工重启 DSH 前看一眼文件）' }

  Info '改动点：WMI.Create 现在使用 $argsRaw（裸命令行）'
  Warn '需要重启 DSH 才会加载这份修改；插件升级会覆盖，升级后请重跑本脚本'
}
exit $exit
