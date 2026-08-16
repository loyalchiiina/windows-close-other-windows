# Windows 一键关闭其他窗口 · Close Other Windows

> 一键关闭 Windows 任务栏上所有打开的软件窗口，**默认保留当前正在使用的窗口**（前台窗口）。
> One-click close all other Windows taskbar windows, keeping your current foreground window.

任务栏窗口太多、想一键全关时用这个：双击桌面快捷方式 → 勾选要关闭的窗口 → 优雅关闭。

## 特性

- 枚举任务栏可见的顶层窗口（与任务管理器 / Alt-Tab 一致），自动排除桌面、任务栏、开始菜单、通知中心等系统 UI
- **默认保留当前前台窗口**（`GetForegroundWindow`），也可按标题关键字 / PID 额外保留
- 用 `WM_CLOSE` 优雅关闭，让应用有机会保存；关闭后**复查并如实报告**未关闭的窗口
- 强制结束进程必须二次确认，且永远跳过系统关键进程（`explorer`、`dwm`、`svchost`、`conhost` 等）
- 三种运行模式：GUI 勾选（桌面双击）/ `-List` 纯扫描 / `-Close` 自动执行

## 快速开始

### 方式一：桌面一键（GUI 勾选模式）

1. 下载本仓库到任意目录
2. 运行 `install-shortcut.ps1`，在桌面创建「一键关闭其他窗口」快捷方式（或按下方手动创建）
3. 双击快捷方式 → 弹出窗口列出所有任务栏窗口，勾选 = 要关闭的窗口（当前窗口默认不勾选）→ 点「关闭勾选窗口」

### 方式二：命令行

```powershell
# 仅扫描：列出任务栏窗口清单（无任何副作用）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close-all-windows.ps1 -List

# 一键关闭（保留当前窗口 + 脚本自身窗口），不弹确认框
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close-all-windows.ps1 -Close -NoConfirm

# 额外保留标题含 Chrome 的窗口、保留 PID 1234
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close-all-windows.ps1 -Close -NoConfirm -KeepTitle "Chrome" -KeepPid 1234

# 对未响应 WM_CLOSE 的窗口强制结束进程（仅在你明确同意后；自动跳过系统关键进程）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close-all-windows.ps1 -Close -NoConfirm -ForceRemaining
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `-List` | 仅列出窗口清单，不执行任何操作 |
| `-Close` | 执行关闭（配合下方参数） |
| `-NoConfirm` | 跳过 GUI 确认弹窗（自动化场景） |
| `-KeepTitle <string[]>` | 保留的窗口标题关键字（模糊匹配，可多个） |
| `-KeepPid <int[]>` | 保留的进程 PID（可多个） |
| `-ForceRemaining` | 对未关闭窗口强制结束进程（自动跳过保护进程） |

无参数运行时进入 **GUI 勾选模式**（桌面一键脚本）。

## 手动创建桌面快捷方式

```powershell
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\一键关闭其他窗口.lnk")
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<本仓库路径>\scripts\close-all-windows.ps1"'
$lnk.WorkingDirectory = Split-Path "<本仓库路径>\scripts\close-all-windows.ps1"
$lnk.IconLocation = 'shell32.dll,22'
$lnk.Save()
```

## 安全设计

- 关闭一律走 `PostMessage(WM_CLOSE)`，让应用有机会保存；**禁止上来就强杀进程**
- 强杀（`Stop-Process`）仅在用户明确同意后执行，且 `$ProtectedProcess` 保护列表中的系统关键进程绝不强杀
- 前台窗口在脚本启动瞬间抓取并默认保留；脚本自身窗口与系统 UI 窗口类永不列入关闭范围
- 关闭后复查 `IsWindow` 并如实报告未关闭项（应用可能正在保存 / 弹窗询问，属正常现象）

## 环境要求

- Windows 7+，PowerShell 5.1+（Windows 10/11 自带）
- 脚本含中文文本，文件编码必须为 **UTF-8 with BOM**（本仓库文件已带 BOM，请勿用无 BOM 编辑器覆盖保存）

## 参考

- `references/EXPERIENCE-LOG.md` — 开发与排障经验台账（GUI 模式崩溃、UTF-8 BOM、`$PID` 只读等踩坑记录）

## License

[MIT](LICENSE)
