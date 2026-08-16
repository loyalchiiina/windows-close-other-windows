#Requires -Version 5.1
<#
.SYNOPSIS
  一键关闭 Windows 任务栏上所有打开的软件窗口，默认保留当前正在使用的窗口。

.DESCRIPTION
  枚举任务栏上的顶层窗口（可见、有标题、非工具窗口/桌面/任务栏自身），
  通过 WM_CLOSE 优雅关闭，保留：
    - 当前前台窗口（GetForegroundWindow）
    - 脚本自身进程的窗口
    - -KeepTitle / -KeepPid 指定的窗口
  关闭后复查未关闭的窗口并报告；强制结束进程必须获得用户明确同意，
  且永远跳过系统关键进程。

.PARAMETER List
  仅列出任务栏窗口清单（无任何副作用），agent 扫描用。

.PARAMETER Close
  执行关闭。配合 -KeepTitle / -KeepPid 指定保留项（前台窗口始终保留）。

.PARAMETER NoConfirm
  关闭前不弹窗确认（仅 agent 已获得用户同意后使用）。

.PARAMETER KeepTitle
  保留的窗口标题关键字（可多个，模糊匹配）。

.PARAMETER KeepPid
  保留的进程 PID（可多个）。

.EXAMPLE
  # 桌面一键脚本（无参数，GUI 勾选模式）
  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File close-all-windows.ps1

.EXAMPLE
  # agent 扫描
  powershell -NoProfile -ExecutionPolicy Bypass -File close-all-windows.ps1 -List

.EXAMPLE
  # agent 执行（保留标题含 Chrome 与 PID 1234 的窗口）
  powershell -NoProfile -ExecutionPolicy Bypass -File close-all-windows.ps1 -Close -NoConfirm -KeepTitle "Chrome" -KeepPid 1234

.EXAMPLE
  # agent 在用户明确同意后，对未关闭窗口强杀（自动跳过系统关键进程）
  powershell -NoProfile -ExecutionPolicy Bypass -File close-all-windows.ps1 -Close -NoConfirm -ForceRemaining
#>

[CmdletBinding()]
param(
  [switch]$List,
  [switch]$Close,
  [switch]$NoConfirm,
  [switch]$ForceRemaining,
  [string[]]$KeepTitle,
  [int[]]$KeepPid
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- Win32 P/Invoke ----------
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TaskbarWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
}
"@

$GWL_EXSTYLE = -20
$WS_EX_APPWINDOW = 0x00040000
$WS_EX_TOOLWINDOW = 0x00000080
$GW_OWNER = 4
$WM_CLOSE = 0x0010

# 不属于"软件窗口"的类：桌面、任务栏、开始菜单/操作中心等系统 UI
$ExcludeClass = @('Progman','WorkerW','Shell_TrayWnd','Shell_SecondaryTrayWnd','Windows.UI.Core.CoreWindow','DV2ControlHost','Shell_InputPanel','WindowsInternal.ComposableShell.Experiences.TextInputHintPopup')

# 强制结束进程时永远跳过的系统关键进程（小写比较）
$ProtectedProcess = @('explorer','dwm','csrss','winlogon','lsass','services','svchost','wininit','smss','fontdrvhost','conhost','system','registry','shell','runtimebroker','sihost','taskhostw','startmenuexperiencehost','searchapp','searchindexer','ctfmon','dllhost')

function Get-WinText([IntPtr]$hWnd) {
  $len = [TaskbarWin32]::GetWindowTextLength($hWnd)
  if ($len -le 0) { return '' }
  $sb = New-Object System.Text.StringBuilder ($len + 1)
  [void][TaskbarWin32]::GetWindowText($hWnd, $sb, $sb.Capacity)
  return $sb.ToString()
}

function Get-WinClass([IntPtr]$hWnd) {
  $sb = New-Object System.Text.StringBuilder 256
  [void][TaskbarWin32]::GetClassName($hWnd, $sb, $sb.Capacity)
  return $sb.ToString()
}

function Get-TaskbarWindows {
  param($ForegroundHwnd)
  $result = New-Object System.Collections.Generic.List[object]
  $cb = [TaskbarWin32+EnumWindowsProc]{
    param($hWnd, $lParam)
    if (-not [TaskbarWin32]::IsWindowVisible($hWnd)) { return $true }

    $cls = Get-WinClass $hWnd
    if ($ExcludeClass -contains $cls) { return $true }

    $title = Get-WinText $hWnd
    if ([string]::IsNullOrWhiteSpace($title)) { return $true }

    # 任务栏可见窗口判定：WS_EX_APPWINDOW，或无所有者且非 WS_EX_TOOLWINDOW
    $ex = [TaskbarWin32]::GetWindowLongPtr($hWnd, $GWL_EXSTYLE)
    $owner = [TaskbarWin32]::GetWindow($hWnd, $GW_OWNER)
    $isAppWindow = (($ex.ToInt64() -band $WS_EX_APPWINDOW) -ne 0) -or
                   ((($ex.ToInt64() -band $WS_EX_TOOLWINDOW) -eq 0) -and $owner -eq [IntPtr]::Zero)
    if (-not $isAppWindow) { return $true }

    $procId = 0
    [void][TaskbarWin32]::GetWindowThreadProcessId($hWnd, [ref]$procId)
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $procName = if ($proc) { $proc.ProcessName } else { '' }

    $result.Add([pscustomobject]@{
      HWnd      = $hWnd
      Title     = $title
      PID       = $procId
      Process   = $procName
      IsForeground = ($hWnd -eq $ForegroundHwnd)
    })
    return $true
  }

  [void][TaskbarWin32]::EnumWindows($cb, [IntPtr]::Zero)
  return $result
}

function Test-ShouldClose($w, $fgHwnd, $selfPid, $keepTitles, $keepPids) {
  if ($w.HWnd -eq $fgHwnd) { return $false }              # 当前窗口始终保留
  if ($w.PID -eq $selfPid) { return $false }              # 脚本自身窗口
  if ($keepPids -contains $w.PID) { return $false }
  foreach ($t in $keepTitles) {
    if (-not [string]::IsNullOrWhiteSpace($t) -and $w.Title -like "*$t*") { return $false }
  }
  return $true
}

function Send-Close([object[]]$targets) {
  foreach ($w in $targets) {
    [void][TaskbarWin32]::PostMessage($w.HWnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
  }
}

function Get-Remaining([object[]]$targets) {
  $targets | Where-Object { [TaskbarWin32]::IsWindow($_.HWnd) }
}

function Invoke-ForceKill([object[]]$remaining) {
  foreach ($w in $remaining) {
    if ($ProtectedProcess -contains $w.Process.ToLower()) {
      Write-Output ("  跳过保护进程: {0}（{1}）" -f $w.Process, $w.Title)
      continue
    }
    Stop-Process -Id $w.PID -Force -ErrorAction SilentlyContinue
    Write-Output ("  已强制结束: PID {0} {1} - {2}" -f $w.PID, $w.Process, $w.Title)
  }
}

# ---------- 主流程 ----------
$selfPid = $PID
$fgHwnd = [TaskbarWin32]::GetForegroundWindow()
$wins = @(Get-TaskbarWindows -ForegroundHwnd $fgHwnd)

if ($List) {
  Write-Output ("任务栏窗口清单（共 {0} 个）：" -f $wins.Count)
  foreach ($w in $wins) {
    $flag = if ($w.IsForeground) { ' [当前窗口-保留]' } else { '' }
    Write-Output ("  PID {0,-6} {1,-28} {2}{3}" -f $w.PID, $w.Process, $w.Title, $flag)
  }
  Write-Output ("当前窗口 HWND={0}（默认保留）" -f $fgHwnd)
  exit 0
}

if ($Close) {
  $targets = @($wins | Where-Object { Test-ShouldClose $_ $fgHwnd $selfPid $KeepTitle $KeepPid })
  $kept = @($wins | Where-Object { -not (Test-ShouldClose $_ $fgHwnd $selfPid $KeepTitle $KeepPid) })

  Write-Output ("待关闭 {0} 个窗口，保留 {1} 个。" -f $targets.Count, $kept.Count)
  foreach ($w in $targets) { Write-Output ("  关闭: PID {0} {1} - {2}" -f $w.PID, $w.Process, $w.Title) }

  if (-not $NoConfirm) {
    $msg = "将关闭 $($targets.Count) 个窗口：`n`n" +
           (($targets | ForEach-Object { "  $($_.Title) [$($_.Process)]" }) -join "`n") +
           "`n`n是否继续？"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, '一键关闭其他窗口', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { Write-Output '用户取消。'; exit 1 }
  }

  Send-Close $targets
  Start-Sleep -Seconds 4

  $remaining = @(Get-Remaining $targets)
  if ($remaining.Count -eq 0) {
    Write-Output ("成功：{0} 个窗口已全部关闭。" -f $targets.Count)
    exit 0
  }

  Write-Output ("{0} 个窗口未响应关闭请求（可能正在保存或弹窗询问）：" -f $remaining.Count)
  foreach ($w in $remaining) { Write-Output ("  未关闭: PID {0} {1} - {2}" -f $w.PID, $w.Process, $w.Title) }

  if ($ForceRemaining) {
    # agent 模式：用户已在对话中明确同意强杀
    Invoke-ForceKill $remaining
  } elseif (-not $NoConfirm) {
    $msg2 = "以下 $($remaining.Count) 个窗口未关闭：`n`n" +
            (($remaining | ForEach-Object { "  $($_.Title) [$($_.Process)]" }) -join "`n") +
            "`n`n是否强制结束这些进程？（未保存内容可能丢失）"
    $r2 = [System.Windows.Forms.MessageBox]::Show($msg2, '强制结束？', 'YesNo', 'Warning')
    if ($r2 -eq 'Yes') {
      Invoke-ForceKill $remaining
    }
  }
  exit 0
}

# ---------- 默认：GUI 勾选模式（桌面一键脚本） ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '一键关闭其他窗口'
$form.Size = New-Object System.Drawing.Size(560, 460)
$form.StartPosition = 'CenterScreen'
$form.MinimizeBox = $false
$form.MaximizeBox = $false

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = '勾选 = 要关闭的窗口（当前窗口已保留，不要取消勾选保留项）：'
$lbl.Location = New-Object System.Drawing.Point(12, 10)
$lbl.AutoSize = $true
$form.Controls.Add($lbl)

$chkList = New-Object System.Windows.Forms.CheckedListBox
$chkList.Location = New-Object System.Drawing.Point(12, 34)
$chkList.Size = New-Object System.Drawing.Size(520, 330)
$chkList.CheckOnClick = $true
$form.Controls.Add($chkList)

$idxMap = New-Object System.Collections.Generic.List[int]
foreach ($w in $wins) {
  $keep = (-not (Test-ShouldClose $w $fgHwnd $selfPid @() @()))
  $disp = "{0}  [{1}]  PID {2}" -f $w.Title, $w.Process, $w.PID
  if ($w.IsForeground) { $disp += '  (当前窗口)' }
  [void]$chkList.Items.Add($disp, (-not $keep))
  [void]$idxMap.Add($idxMap.Count)
}
$script:winMap = $wins

$btnSel = New-Object System.Windows.Forms.Button
$btnSel.Text = '全选'
$btnSel.Location = New-Object System.Drawing.Point(12, 376)
$btnSel.Size = New-Object System.Drawing.Size(80, 30)
$form.Controls.Add($btnSel)

$btnNone = New-Object System.Windows.Forms.Button
$btnNone.Text = '全部取消'
$btnNone.Location = New-Object System.Drawing.Point(98, 376)
$btnNone.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnNone)

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = '关闭勾选窗口'
$btnGo.Location = New-Object System.Drawing.Point(240, 376)
$btnGo.Size = New-Object System.Drawing.Size(140, 30)
$form.Controls.Add($btnGo)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消'
$btnCancel.Location = New-Object System.Drawing.Point(450, 376)
$btnCancel.Size = New-Object System.Drawing.Size(80, 30)
$form.Controls.Add($btnCancel)

$btnSel.Add_Click({ for ($i = 0; $i -lt $chkList.Items.Count; $i++) { $chkList.SetItemChecked($i, $true) } })
$btnNone.Add_Click({ for ($i = 0; $i -lt $chkList.Items.Count; $i++) { $chkList.SetItemChecked($i, $false) } })
$btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })

$btnGo.Add_Click({
  $checkedIdx = @()
  for ($i = 0; $i -lt $chkList.Items.Count; $i++) { if ($chkList.GetItemChecked($i)) { $checkedIdx += $i } }
  if ($checkedIdx.Count -eq 0) {
    [void][System.Windows.Forms.MessageBox]::Show('没有勾选任何窗口。', '提示', 'OK', 'Information')
    return
  }
  $targets = @($checkedIdx | ForEach-Object { $script:winMap[$_] })
  $r = [System.Windows.Forms.MessageBox]::Show(
    ("将关闭 {0} 个窗口，是否继续？" -f $targets.Count), '确认', 'YesNo', 'Warning')
  if ($r -ne 'Yes') { return }

  Send-Close $targets
  Start-Sleep -Seconds 4
  $remaining = @(Get-Remaining $targets)
  if ($remaining.Count -gt 0) {
    $msg = ("{0} 个窗口未关闭：`n`n" -f $remaining.Count) +
           (($remaining | ForEach-Object { "  $($_.Title) [$($_.Process)]" }) -join "`n") +
           "`n`n是否强制结束这些进程？"
    $r2 = [System.Windows.Forms.MessageBox]::Show($msg, '强制结束？', 'YesNo', 'Warning')
    if ($r2 -eq 'Yes') {
      Invoke-ForceKill $remaining
    }
  }
  [void][System.Windows.Forms.MessageBox]::Show(
    ("完成：已请求关闭 {0} 个窗口，剩余未关闭 {1} 个。" -f $targets.Count, $remaining.Count),
    '完成', 'OK', 'Information')
  $form.DialogResult = 'OK'
  $form.Close()
})

[void]$form.ShowDialog()
