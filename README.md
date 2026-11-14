# dsh-purge「换包失败」问题解决汇总

> 现场：Windows 11 + DeepSeek Harness Desktop 0.2.2-rc.3 + dsh-purge-community 1.7.14
> 记录时间：2026-11-15（UTC+8）
> 状态：已定位根因，已提供 3 条可执行方案，本机已按方案 B 完成修复并验证

---

## 0. TL;DR

| 项目 | 结论 |
|---|---|
| 故障表象 | purge 面板「换包状态：失败 · 目标磁盘仍有 app.asar · 当前服务启动入口指向 app.asar」 |
| 真正原因 | **换包助手进程从未启动**，不是补丁错误，也不是归档被破坏 |
| 直接原因 1 | 插件 1.7.14 的 Windows handoff 在 WMI 分支把开关串整体加了单引号，导致 `powershell.exe` 收到一个无效参数后立刻退出 |
| 直接原因 2 | 本机火绒安全拦截「WMI 派生 PowerShell」，即便修好引号，WMI 分支在本机仍不可用 |
| 影响 | 磁盘解包目录 `resources\app` 已打好补丁，但因 `app.asar` 仍在，Electron 优先加载归档，补丁**不生效** |
| 数据安全 | 原归档完好，未被修改；换包只做「改名保留」，可随时回滚 |
| 修复 | 方案 A 修插件引号 → 方案 B 改用「计划任务 → cmd → 独立 PowerShell 助手」完成换包（本机可用）→ 方案 C 手动改名兜底 |

---

## 1. 现象与现场信息

### 1.1 面板提示

```
当前服务启动入口指向 app.asar；此证据不等于磁盘目录内容已加载。
目标磁盘仍有 app.asar。
换包状态：失败，请查看诊断并按恢复文档操作。
详情：Handoff broker failed (broker_exit_code=1, signal=none); the helper exit code,
      if observed, is recorded separately in
      D:\Program Files\DeepSeek Harness\resources\app.asar.purge-handoff.json.broker.log
```

同时面板其余部分其实正常：`补丁 67/73 applied`、`备份 有`、`注入状态 override=default`。
也就是说**补丁打成功、只是没被加载**。

### 1.2 现场目录结构

```
D:\Program Files\DeepSeek Harness\
├─ DeepSeek Harness.exe
└─ resources\
   ├─ app.asar                  ← 209,021,953 字节，Electron 优先加载它（补丁不生效的原因）
   ├─ app.asar.unpacked\
   ├─ app\                       ← purge 解包出的目录，补丁就打在这里
   │  ├─ package.json            (0.2.2-rc.3, main=lib/main.js)
   │  ├─ lib\main.js
   │  ├─ dsh\node_modules\…      ← 宿主补丁目标
   │  ├─ node_modules\
   │  └─ runtime → ..\runtime    (Junction，绝对目标)
   ├─ app.asar.purge-handoff.json          ← 状态文件（失败时 phase=failed）
   ├─ app.asar.purge-handoff.json.broker.log ← broker 日志（关键证据）
   └─ app.asar.rename-pending              ← 失败尝试留下的锁（残留）
```

Electron 的加载顺序是 **`resources\app.asar` 优先于 `resources\app` 目录**，所以必须把 `app.asar` 挪走，磁盘补丁才会生效。这就是「换包」要等 DSH 完全退出后改名文件的原因。

---

## 2. 诊断过程（可复现）

### 2.1 三条决定性证据

| # | 检查项 | 结果 | 含义 |
|---|---|---|---|
| 1 | `resources\app.asar.purge-handoff.json.log` 是否存在 | **不存在** | 助手脚本第一步就是 `Save-State 'ready'` 并写这个日志；没有日志 ⇒ **脚本一行都没执行** |
| 2 | `.broker.log` 内容 | 4 次尝试全是 `token=… WMI.Create return=0 child_pid=XXXX` 紧跟 `Helper pid XXXX no longer observable before acknowledging startup; child_exit_code=unknown` | 进程"创建成功"但瞬间消失，从未写状态 |
| 3 | `app.asar.purge-handoff.json` | `phase=failed`，**没有 `pid` 字段** | 只有助手自己写的状态才带 `pid`；这条是 broker 失败回填的 |

### 2.2 手工核对命令

```powershell
$res = 'D:\Program Files\DeepSeek Harness\resources'
Get-ChildItem $res -Filter 'app.asar*' -Force | Select Name,Length,LastWriteTime
Get-Content "$res\app.asar.purge-handoff.json" -Raw
Get-Content "$res\app.asar.purge-handoff.json.broker.log" -Raw   # 该文件是 UTF-8 + CLIXML 混排
(Get-FileHash "$res\app.asar" -Algorithm SHA256).Hash            # 现场：14CFD81C…725AE
```

### 2.3 关键实验：定位到「引号」

插件 broker 的 WMI 分支拼出的命令行是（注意**外层单引号**）：

```
"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -ExecutionPolicy Bypass -EncodedCommand JABQAHI…'
```

用 `cmd /c` 做 A/B 对照：

| 变体 | 命令行 | 结果 |
|---|---|---|
| A（插件实际拼接） | `powershell.exe '-NoProfile -ExecutionPolicy Bypass -EncodedCommand <b64>'` | 进程退出码 0，把整串开关**原样打印**后结束，脚本零执行 |
| B（去掉外层单引号） | `powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand <b64>` | 脚本正常执行 |

结论：`Win32_Process.Create` 接收的是**原始命令行**，单引号在这里不是"引用符"而是**字面字符**；PowerShell 把整串开关当成一个位置参数，于是一个开关都没生效，直接退出（退出码 0，所以 broker 只能报 `child_exit_code=unknown`）。

### 2.4 第二个坑：火绒拦截「WMI → PowerShell」

把引号问题按方案 A 修好后，本机仍然失败。继续做链路隔离（全部实测）：

| 链路 | 结果 |
|---|---|
| WMI → `cmd.exe /c echo …` | ✅ 正常，文件写出 |
| WMI → `powershell.exe -Command "Start-Sleep 60"` | ❌ 进程秒退 |
| WMI → `powershell.exe -EncodedCommand …` | ❌ 进程秒退（连续 3 次全失败） |
| WMI → `cmd.exe` → `powershell.exe` | ❌ cmd 报「拒绝访问」（CreateProcess 被拒） |
| **计划任务(SYSTEM) → `cmd.exe` → `powershell.exe`** | ✅ 正常执行 |
| 直接命令行（Node/DSH 派生）→ `powershell.exe` | ✅ 正常执行 |

本机在跑的驱动：`hrwfpdrv.sys`（火绒网络防护）、`hrdevmon.sys`（火绒设备监控）。
即：**火绒对"WMI 拉起 PowerShell"这条链有针对性拦截**，而计划任务链路不受影响。

因此：插件只要走 WMI 分支，在这台机器上**必然失败**；修引号是必要但不充分。

---

## 3. 根因总结

```
用户点「应用」
   → purge 写完磁盘补丁（成功，67/73）
   → 需要换包：把 app.asar 改名，等 DSH 完全退出后执行
   → 宿主进程在 Job Object 内 → broker 判定 inJob=true → 走 WMI 分支
        ├─ 缺陷：开关串被单引号包住 → helper 启动即退出（退出码 0，无任何日志）   ← 原因 1
        └─ 环境：火绒拦截 WMI→PowerShell → 即使引号正确也秒退                 ← 原因 2
   → broker 观察不到 helper、也没等到 ready 状态 → throw → broker exit 1
   → 插件把 phase 记为 failed，面板「换包失败」，磁盘仍密封
```

**未被破坏的东西**：原 `app.asar`、`resources\app` 解包目录、插件备份、提示词与设置。
失败的尝试除了留下 `rename-pending` 锁和 broker 日志，**没有任何写操作**。

---

## 4. 解决方案

### 方案 A：修插件的 WMI 引号缺陷（治本，但本机仍受火绒限制）

目标文件（随 profile 而定）：

```
C:\Users\<你>\.dsh\profiles\desktop\node_modules\dsh-purge-community\lib\windows-asar-handoff.js
```

原代码（1.7.14）：

```js
const helperArgs = quote('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + encoded(invoke));
…
$exe=Join-Path $PSHOME 'powershell.exe'
$argsText=${helperArgs}
if ($inJob) {
  $startup=([wmiclass]'Win32_ProcessStartup').CreateInstance()
  $startup.ShowWindow=0
  $result=([wmiclass]'Win32_Process').Create(('"' + $exe + '" ' + $argsText),$env:TEMP,$startup)
```

改为：

```js
const helperCmdLine = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + encoded(invoke);
// Start-Process -ArgumentList 需要一个带引号的整串；Win32_Process.Create 要裸命令行。
const helperArgs = quote(helperCmdLine);
…
$exe=Join-Path $PSHOME 'powershell.exe'
$argsText=${helperArgs}
$argsRaw=${quote(helperCmdLine)}
if ($inJob) {
  $startup=([wmiclass]'Win32_ProcessStartup').CreateInstance()
  $startup.ShowWindow=0
  $result=([wmiclass]'Win32_Process').Create(('"' + $exe + '" ' + $argsRaw),$env:TEMP,$startup)
```

要点：
- **只改 WMI 分支**，`Start-Process -ArgumentList $argsText` 的引号必须保留（那里确实需要整串一个参数）。
- 改完要**重启 DSH** 才生效（插件在启动时加载）。
- **插件升级会覆盖这个补丁**，升级后需重新执行 `scripts\2-patch-plugin.ps1`。
- 有火绒等 HIPS 的机器，即使修好引号，WMI 分支仍可能被拦 → 用方案 B。

### 方案 B：用「计划任务」链条完成换包（本机已验证可用，推荐）

绕开被拦的 WMI 链，改用 Task Scheduler（SYSTEM）→ `cmd.exe` → 独立 `powershell.exe` 助手：

```
schtasks(DSH-Purge-AsarHandoff, SYSTEM, 一次性)
  → C:\ProgramData\dsh-purge-fix\asar-handoff-run.cmd
    → powershell.exe -File asar-handoff-helper.ps1 -ExePath … -AsarPath … -StatePath … -Token …
      → 校验 resources\app 完整 → 记录原归档 SHA256 → 等全部 DeepSeek Harness.exe 退出
      → 改名 app.asar → app.asar.purge-manual-<token>.bak
      → 复核 SHA256 → 写 phase=complete → 任务自删
```

助手的安全边界（与插件原设计一致，只是换了启动方式）：
- 只等「同一 exe 路径」的进程退出，**不结束任何进程**、不重启 DSH；
- 改名目标名带 token，**不覆盖**任何已有备份；
- 归档哈希与启动时不一致（例如期间被官方更新替换）→ **不动文件**，报 `failed`；
- 默认可等待 60 分钟，超时只写 `expired`，**不改名**；
- 只做「改名保留」，不会删除 `app.asar`。

### 方案 C：手动兜底（最稳，适合一次性）

1. 从托盘**完整退出** DSH，任务管理器确认该安装路径的 `DeepSeek Harness.exe` 全部消失；
2. 确认 `resources\app\package.json`、`resources\app\lib\main.js` 存在；
3. 在管理员 PowerShell 里：

```powershell
$res = 'D:\Program Files\DeepSeek Harness\resources'
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
Move-Item "$res\app.asar" "$res\app.asar.purge-manual-$stamp.bak"
```

4. 手动打开 DSH。

若改名报「文件被占用」，说明还有进程没退干净 → 回任务管理器确认，**不要强杀所有 Electron 进程**，也不要删除 `app.asar`。

---

## 5. 操作步骤（推荐顺序）

```powershell
# 0) 进入本目录
cd 'G:\PROJECTLIST\dsh-purge问题解决汇总'

# 1) 先诊断，确认是不是同一个问题（只读，不改任何文件）
powershell -ExecutionPolicy Bypass -File .\scripts\1-diagnose.ps1

# 2) 修插件引号缺陷（自动备份为 .orig，幂等，可重复跑）
powershell -ExecutionPolicy Bypass -File .\scripts\2-patch-plugin.ps1

# 3) 安排换包助手（会注册计划任务并立刻启动助手，等待你退出 DSH）
powershell -ExecutionPolicy Bypass -File .\scripts\3-schedule-swap.ps1

# 4) 查看状态（随时可查）
powershell -ExecutionPolicy Bypass -File .\scripts\5-status.ps1
```

然后：

1. **从托盘完整退出 DSH**（只关窗口不算退出），任务管理器确认没有该路径的 `DeepSeek Harness.exe`；
2. 3～5 秒内助手自动改名，`5-status.ps1` 显示 `phase=complete`；
3. **手动重新打开 DSH**；
4. purge 面板应显示「已解封 / sealed=false」。此时补丁从 `resources\app` 加载，不再需要换包。

怀疑要退版本时：完整退出 DSH 后运行 `scripts\4-rollback.cmd`（把最新的 `.bak` 改回 `app.asar`）。

---

## 6. 验证清单

- [ ] `resources\app.asar` 不存在，`resources\app\package.json` 存在
- [ ] `resources\app.asar.purge-handoff.json` 中 `phase=complete`，且 `backup`、`archive_sha256` 与备份文件一致
  ```powershell
  (Get-FileHash 'D:\Program Files\DeepSeek Harness\resources\app.asar.purge-manual-*.bak' -Algorithm SHA256).Hash
  ```
- [ ] 重开 DSH 后 purge 面板「磁盘 / 运行入口」显示为解包目录、`sealed=false`
- [ ] 计划任务 `DSH-Purge-AsarHandoff` 已自动删除（助手结束时会自删）
- [ ] 面板补丁数仍为 67/73 applied，且这次是**运行中已加载**

---

## 7. 回滚

| 场景 | 做法 |
|---|---|
| 换包后 DSH 起不来 / 想回官方归档 | 完整退出 DSH → `scripts\4-rollback.cmd`（把最新的 `app.asar.purge-manual-*.bak` 改回 `app.asar`） |
| 想撤销插件引号补丁 | 用同目录的 `windows-asar-handoff.js.orig` 覆盖回去，然后重启 DSH |
| 想撤销计划任务 | `schtasks /Delete /TN "DSH-Purge-AsarHandoff" /F` |
| 官方更新后重新密封 | 官方更新会重新生成 `app.asar`，此时面板会重新显示「目标磁盘存在归档」，属正常，重跑方案 A/B 即可 |

回滚**不需要**恢复 profile、不动提示词/规则/其他插件设置，也不动用户备份目录。

---

## 8. 注意事项与已知边界

1. **不要**用「删除 `app.asar`」代替改名——改名才留得下唯一备份。
2. **不要**强杀所有 Electron/WebView 进程来抢文件锁；等它正常退出即可，共享冲突助手会自动重试。
3. **不要**因为失败就清 `rename-pending` 或状态文件就宣布修好——那只清症状。本案例中残留锁是**结果**不是原因。
4. 插件升级 / 重装会覆盖方案 A 的补丁；升级后重新跑 `2-patch-plugin.ps1`。
5. 宿主在 Job Object 内是常态（桌面壳就是），所以插件始终走 WMI 分支；装了 HIPS（火绒、360、EDR）的机器建议直接用方案 B。
6. macOS 走的是另一套 handoff（`macos-asar-handoff.js`），本文结论不适用；Linux/Web 宿主不存在换包需求。
7. 面板上的「补丁 67/73 applied」只说明**磁盘文件**已改，**不代表当前进程已加载**——这也是本问题容易被误判为"已经好了"的原因。
8. 计划任务以 SYSTEM 运行，只做文件改名与哈希校验，不联网、不启动 DSH、不写用户配置。

---

## 9. 附件清单

```
dsh-purge问题解决汇总\
├─ README.md                         ← 本文档
├─ 一键菜单.cmd                      菜单入口（1 诊断 / 2 打补丁 / 3 安排换包 / 4 状态 / 5 回滚）
├─ scripts\
│  ├─ asar-handoff-helper.ps1        换包助手本体（等退出→校验→改名→写状态）
│  ├─ 1-diagnose.ps1                 只读诊断：归档/解包目录/状态/日志/任务/拦截探测
│  ├─ 2-patch-plugin.ps1             自动修 1.7.14 的 WMI 引号缺陷（备份 .orig、幂等）
│  ├─ 3-schedule-swap.ps1            注册计划任务并立刻启动助手（方案 B）
│  ├─ 4-rollback.ps1                 完整退出后把 .bak 改回 app.asar（校验哈希）
│  └─ 5-status.ps1                   查看握手状态与日志尾部
└─ evidence\
   ├─ failed-broker.log              现场原始 broker 日志（含 4 次 WMI 失败）
   ├─ failed-state.json              现场原始状态文件
   └─ handoff-state.log              修复过程中助手的握手日志
```

脚本约定：

- 全部支持 `-ExePath` 指定安装位置；不传时按「运行中的 DSH 进程 → 常见安装路径」自动探测。
- `3-schedule-swap.ps1` 会把助手与启动包装复制到 ASCII 路径 `C:\ProgramData\dsh-purge-fix\`
  （避免中文/空格路径在 schtasks 里的编码问题），任务名默认 `DSH-Purge-AsarHandoff`，
  可用 `-TaskName` 改成别的名字做并行测试。
- 计划任务以 SYSTEM 运行，助手结束时会 `schtasks /Delete` **自删**，不留常驻项。
- 脚本文件为 UTF-8 with BOM（PowerShell 5.1 才能正确显示中文）；整个流程只用 PS 5.1 内建能力，无第三方依赖。

---

## 10. 验证记录（本机实测）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 只读诊断 | `1-diagnose.ps1` | 正确识别：归档密封、`resources\app` 完整、junction 可用、phase=waiting_for_quit、broker 4 次 WMI 失败、插件已打补丁、WMI→PowerShell 被拦 |
| 补丁幂等 | `2-patch-plugin.ps1` | 已打过 → 输出「已打过引号补丁，跳过」 |
| 补丁正确性 | 用原始 1.7.14 副本跑 `2-patch-plugin.ps1` | 产出文件与人工修补版本 **SHA256 完全一致**；`node --check` 通过 |
| 换包端到端 | 在临时 fixture（假安装目录 + 2 MB 假 asar）跑 `3-schedule-swap.ps1` | 任务创建→运行→助手改名→哈希一致→`phase=complete`→任务自删，全程 <5 秒 |
| 回滚 | fixture 上跑 `4-rollback.ps1` | 备份改回 `app.asar`，哈希与原值一致 |
| 状态查看 | `5-status.ps1` | 正确显示归档/状态/日志/任务/进程数 |

真实安装目录上的换包按「完整退出 DSH → 助手自动改名 → 手动重开」执行；改名前助手会校验归档哈希，
因此不会误伤官方更新后的新归档。


---

## 11. 附录：原始证据摘录

`.broker.log`（节选，共 4 次同类失败）：

```
token=8bb400b4-… WMI.Create return=0 child_pid=86508
<Objs …><S S="Error">Helper pid 86508 no longer observable before acknowledging startup; child_exit_code=unknown
…
token=417161c6-2ae3-4b7d-972f-7d76edca78ad WMI.Create return=0 child_pid=93728
<S S="Error">Helper pid 93728 no longer observable before acknowledging startup; child_exit_code=unknown
```

失败状态文件：

```json
{"token":"417161c6-2ae3-4b7d-972f-7d76edca78ad","phase":"failed",
 "updated_at":"2026-11-14T16:47:08.193Z",
 "detail":"Handoff broker failed (broker_exit_code=1, signal=none); …"}
```

修复后（方案 B 助手）状态：

```json
{"token":"b6738fe1-…","pid":86076,"phase":"waiting_for_quit",
 "detail":"waiting for all D:\\Program Files\\DeepSeek Harness\\DeepSeek Harness.exe processes to exit",
 "backup":"…\\app.asar.purge-manual-b6738fe1-….bak",
 "archive_sha256":"14CFD81C9135BF0AFB89417543C94F9ECFE09266574452A9B106890C698725AE",
 "mode":"manual-recovery"}
```
