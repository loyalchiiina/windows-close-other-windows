#Requires -Version 5.1
<#
.SYNOPSIS
  在桌面创建「一键关闭其他窗口」快捷方式，指向本目录下的 close-all-windows.ps1。

.DESCRIPTION
  双击运行本脚本即可创建/修复桌面快捷方式：
    powershell -NoProfile -ExecutionPolicy Bypass -File install-shortcut.ps1
  快捷方式以隐藏窗口运行 GUI 勾选模式，图标 shell32.dll,22。
  本脚本可放在仓库任意位置（自动按脚本所在目录定位 close-all-windows.ps1）。
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $scriptDir 'scripts\close-all-windows.ps1'
if (-not (Test-Path -LiteralPath $target)) {
  $target = Join-Path $scriptDir 'close-all-windows.ps1'
}
if (-not (Test-Path -LiteralPath $target)) {
  Write-Error "找不到 close-all-windows.ps1（已尝试 scripts\ 与脚本同目录）"
  exit 1
}

$ws = New-Object -ComObject WScript.Shell
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) '一键关闭其他窗口.lnk'
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $target + '"'
$lnk.WorkingDirectory = Split-Path -Parent $target
$lnk.IconLocation = 'shell32.dll,22'
$lnk.Save()

Write-Output "已创建/更新桌面快捷方式: $lnkPath"
Write-Output "目标脚本: $target"
