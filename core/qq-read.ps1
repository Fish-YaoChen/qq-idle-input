# qq-read.ps1 — 不碰键鼠，从 QQ 无障碍树里读会话和消息。
#
# 前提：QQ 用 --force-renderer-accessibility 启动（11-20 验过，参数能透到 Chromium）。
# 它只读：不进会话、不发消息、不动焦点。要给会话发消息用 qq-send.ps1。
#
# 用法：
#   powershell -File qq-read.ps1                          # 列出会话（默认自动找小肥鱼那个进程）
#   powershell -File qq-read.ps1 -Sessions                 # 只列会话
#   powershell -File qq-read.ps1 -Open "妈妈" -Messages    # 点开会话读消息（Invoke，不碰鼠标）
#   powershell -File qq-read.ps1 -Uin 2727950855 -Json     # 输出 JSON
param(
  [string]$Uin = "2727950855",
  [string]$Open,
  [switch]$Sessions,
  [switch]$Messages,
  [switch]$Json,
  [int]$MaxMessages = 30
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class QQWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] public struct WPLACE { public uint length, flags, showCmd; public POINT min, max; public RECT normal; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WPLACE w);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  // 11-21：窗口缩着的时候 GetWindowRect 只回一个小矩形（实测 160x28），
  // 拿它比面积，会输给旁边那张「资料卡」浮窗（390x475），于是操作到浮窗身上。
  // 最小化时改用「还原后」的位置来比。
  public static long AreaOf(IntPtr h) {
    if (IsIconic(h)) {
      var w = new WPLACE(); w.length = (uint)Marshal.SizeOf(typeof(WPLACE));
      if (GetWindowPlacement(h, ref w)) {
        long aw = Math.Abs((long)(w.normal.R - w.normal.L) * (w.normal.B - w.normal.T));
        if (aw > 0) return aw;
      }
    }
    RECT r; if (!GetWindowRect(h, out r)) return 0;
    return Math.Abs((long)(r.R - r.L) * (r.B - r.T));
  }
  public static IntPtr FindByPid(uint pid) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, p) => {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp != pid) return true;
      var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
      if (sb.ToString() != "Chrome_WidgetWin_1") return true;
      long a = AreaOf(h);
      if (a > area) { area = a; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
'@

# 找进程：命令行里带 --from-multiple-login <uin>
$proc = Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" |
  Where-Object { $_.CommandLine -like "*--from-multiple-login $Uin *" } | Select-Object -First 1
if (-not $proc) { Write-Error "没找到 QQ $Uin 的进程"; exit 2 }
$pidQQ = [uint32]$proc.ProcessId
if (-not ($proc.CommandLine -like "*force-renderer-accessibility*")) {
  Write-Warning "这个实例没带 --force-renderer-accessibility。窗口渲染过一次之后树多半还在（11-21 实测），读不通再加这个参数。"
}
$hwnd = [QQWin]::FindByPid($pidQQ)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "没找到 $Uin 的窗口"; exit 3 }

$win = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)

function Get-Sessions {
  # 一行会话 = 一个 Group，它的**直接**子节点里有 2~3 个 Text（昵称、时间、预览）。
  # 11-20 第一版按「子孙里有 2 个以上 Text」找，结果把包着整个列表的外层 Group
  # 也当成一行，输出里出现一大段拼起来的怪物。改成只看直接子节点。
  $list = @()
  $textCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Text)
  $groups = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Group)))
  foreach ($g in $groups) {
    $kids = $g.FindAll([System.Windows.Automation.TreeScope]::Children, $textCond)
    if ($kids.Count -lt 2 -or $kids.Count -gt 3) { continue }
    $names = @(); foreach ($t in $kids) { if ($t.Current.Name) { $names += $t.Current.Name } }
    if ($names.Count -eq 0) { continue }
    # 这一行要么自己支持 Invoke，要么它的父 Group 支持
    $clickable = $g
    if (-not ($g.GetSupportedPatterns() | Where-Object { $_ -eq [System.Windows.Automation.InvokePattern]::Pattern })) {
      $p = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($g)
      if ($p) { $clickable = $p }
    }
    $list += [pscustomobject]@{
      会话 = $names[0]
      时间 = $(if ($names.Count -ge 2) { $names[1] } else { "" })
      预览 = $(if ($names.Count -ge 3) { $names[2] } else { "" })
    }
  }
  return $list
}

# 11-20 两次把 QQ 卡死，都是对**藏进托盘的窗口**做 Invoke。
# 规矩：窗口不可见时先显示出来（不抢焦点），再操作；显示不出来就拒。
function Ensure-Visible {
  Add-Type @"
using System; using System.Runtime.InteropServices;
public static class __RDV { [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@ -ErrorAction SilentlyContinue
  if ([__RDV]::IsWindowVisible($hwnd)) { return $true }
  [__RDV]::ShowWindow($hwnd, 4) | Out-Null      # SW_SHOWNOACTIVATE
  Start-Sleep -Milliseconds 900
  return [__RDV]::IsWindowVisible($hwnd)
}

function Open-Session([string]$name) {
  if (-not (Ensure-Visible)) { Write-Error "窗口显示不出来，不做任何操作（对隐藏窗口 Invoke 会把 QQ 卡死）"; return $false }
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, $name)
  $t = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if (-not $t) { Write-Error "会话列表里没找到「$name」"; return $false }
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cur = $t
  for ($i = 0; $i -lt 5; $i++) {
    $cur = $walker.GetParent($cur); if (-not $cur) { break }
    $pats = $cur.GetSupportedPatterns()
    if ($pats | Where-Object { $_ -eq [System.Windows.Automation.InvokePattern]::Pattern }) {
      $cur.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
      Start-Sleep -Milliseconds 600
      return $true
    }
  }
  Write-Error "「$name」这一行不支持 Invoke"
  return $false
}

function Get-Messages([int]$max) {
  $win2 = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $all2 = $win2.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $textCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Text)
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $msgs = @()
  $lastTime = $null
  foreach ($e in $all2) {
    $cls = $e.Current.ClassName
    if ($cls -eq "message__timestamp no-copy") {
      $t = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
      if ($t.Count -gt 0) { $lastTime = $t[0].Current.Name }
      continue
    }
    if ($cls -notlike "msg-content-container*") { continue }
    # 只取最外层那个容器：祖上也挂着 msg-content-container 的就是内层的重复
    $p = $walker.GetParent($e); $nested = $false
    while ($p) {
      if ($p.Current.ClassName -like "msg-content-container*") { $nested = $true; break }
      $p = $walker.GetParent($p)
    }
    if ($nested) { continue }
    $mine = $cls -like "*container--self*"
    $txt = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
    $body = @(); $seen = @{}
    foreach ($x in $txt) {
      $nm = $x.Current.Name
      if ($nm -and -not $seen.ContainsKey($nm)) { $seen[$nm] = 1; $body += $nm }
    }
    if ($body.Count) {
      $msgs += [pscustomobject]@{
        时间 = $lastTime
        谁 = $(if ($mine) { "我" } else { "对方" })
        内容 = ($body -join "`n")
      }
    }
  }
  if ($msgs.Count -gt $max) { $msgs = $msgs[($msgs.Count - $max)..($msgs.Count - 1)] }
  return $msgs
}

if (-not $Messages -or $Open) {
  $s = Get-Sessions
  if ($Json) { $s | ConvertTo-Json -Depth 4 } else {
    "=== 会话 $($s.Count) 个 ==="
    $s | ForEach-Object { "  {0,-10} {1,-10} {2}" -f $_.会话, $_.时间, ($_.预览 -replace "`n", " ") }
  }
}

if ($Open) {
  if (Open-Session $Open) {
    if ($Messages -or $Json) {
      $m = Get-Messages $MaxMessages
      if ($Json) { $m | ConvertTo-Json -Depth 4 } else {
        "=== 「$Open」最近 $($m.Count) 条 ==="
        $m | ForEach-Object { "  [$($_.时间)] $($_.谁)：$(($_.内容 -replace "`n"," ").Substring(0,[Math]::Min(60,($_.内容 -replace "`n"," ").Length)))" }
      }
    }
  }
}
