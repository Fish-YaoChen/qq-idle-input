# qq-repaint.ps1 —— 窗口白了，把它叫回来重画一次
#
# 症状：QQ 窗口整片白，但无障碍树是好的（元素、文本节点都在）。
#       那是渲染层不画了，不是页面坏了——常见于长时间缩在托盘/最小化之后。
# 做法：还原窗口（不抢焦点）→ 尺寸抖一像素 → 再看文本节点数。
#       不重启 QQ、不动登录态、不碰桥。
#
# 用法：
#   .\qq-repaint.ps1            # 自动挑带 --force-renderer-accessibility 的实例
#   .\qq-repaint.ps1 -Uin <你的号>
#   .\qq-repaint.ps1 -DryRun    # 只报告窗口状态，不动

[CmdletBinding()]
param(
  [string]$Uin,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ("__WW" -as [type])) {
  Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class __WW {
 public delegate bool EnumProc(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
 public static IntPtr[] List(uint pid) {
   var l = new List<IntPtr>();
   EnumWindows((h, p) => {
     uint wp; GetWindowThreadProcessId(h, out wp);
     if (wp != pid) return true;
     var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
     if (sb.ToString() != "Chrome_WidgetWin_1") return true;
     l.Add(h); return true;
   }, IntPtr.Zero);
   return l.ToArray();
 }
 public static long Area(IntPtr h) { RECT r; if (!GetWindowRect(h, out r)) return 0; return Math.Abs((long)(r.R - r.L) * (r.B - r.T)); }
 public static int[] Size(IntPtr h) { RECT r; if (!GetWindowRect(h, out r)) return new int[]{0,0}; return new int[]{ r.R - r.L, r.B - r.T }; }
 public static bool Min(IntPtr h) { return IsIconic(h); }
 public static bool Vis(IntPtr h) { return IsWindowVisible(h); }
}
"@
}

function Get-Count([IntPtr]$h) {
  try {
    $ae = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $all = $ae.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $txt = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Text)
    $t = $ae.FindAll([System.Windows.Automation.TreeScope]::Descendants, $txt)
    return @{ elems = $all.Count; texts = $t.Count }
  } catch { return @{ elems = -1; texts = -1 } }
}

# ---- 找实例 ----
# 11-21 改：不再要求「必须带 --force-renderer-accessibility」。窗口渲染过一次之后树就在，
# 不带参数照样能读（见 KNOWN-ISSUES 十五）。带参数的优先挑，没有就用普通实例。
$all = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" | Where-Object {
  $_.CommandLine -match 'from-multiple-login\s+\d+' -and ($Uin -eq '' -or $_.CommandLine -match $Uin)
})
$procs = @($all | Where-Object { $_.CommandLine -match '--force-renderer-accessibility' })
if ($procs.Count -eq 0) { $procs = $all }
if ($procs.Count -eq 0) {
  if ($Uin -ne '') { Write-Host "没找到登录 $Uin 的 QQ 实例。" -ForegroundColor Red }
  else { Write-Host "没找到 QQ 实例——QQ 没开。" -ForegroundColor Red }
  exit 1
}
$qqPid = ($procs | Select-Object -First 1).ProcessId
Write-Host "实例 PID=$qqPid"

# ---- 按元素数挑主窗（缩着的时候面积不可信）----
$best = [IntPtr]::Zero; $bestN = -1; $bestArea = -1
foreach ($h in [__WW]::List([uint32]$qqPid)) {
  $c = Get-Count $h
  $a = [__WW]::Area($h)
  if ($c.elems -gt $bestN -or ($c.elems -eq $bestN -and $a -gt $bestArea)) { $best = $h; $bestN = $c.elems; $bestArea = $a }
}
if ($best -eq [IntPtr]::Zero) { Write-Host "这个进程没有窗口。" -ForegroundColor Red; exit 1 }

$before = Get-Count $best
Write-Host ("主窗 hwnd={0}  可见={1}  最小化={2}  元素={3}  文本节点={4}" -f $best, [__WW]::Vis($best), [__WW]::Min($best), $before.elems, $before.texts)

if ($DryRun) { Write-Host "（-DryRun：只报告，不动）"; exit 0 }

# ---- 还原 + 抖一像素，逼它重画 ----
if ([__WW]::Min($best) -or -not [__WW]::Vis($best)) {
  # SW_SHOWNOACTIVATE：显示出来但不抢焦点
  Write-Host "把它叫出来（不抢焦点）…"
  [void][__WW]::ShowWindow($best, 4)
  Start-Sleep -Milliseconds 600
}
$sz = [__WW]::Size($best)
$w = $sz[0]; $h2 = $sz[1]
if ($w -lt 200 -or $h2 -lt 200) {
  Write-Host "窗口矩形只有 ${w}x${h2}，缩着的时候改尺寸没意义——先手动把窗口拉出来，或者重启这个实例。" -ForegroundColor Yellow
  exit 2
}
# SWP_NOMOVE(0x2) | SWP_NOZORDER(0x4)：只改尺寸，不挪位置、不改层级，也不抢焦点
[void][__WW]::SetWindowPos($best, [IntPtr]::Zero, 0, 0, $w - 1, $h2, 0x0006)
Start-Sleep -Milliseconds 250
[void][__WW]::SetWindowPos($best, [IntPtr]::Zero, 0, 0, $w, $h2, 0x0006)
Start-Sleep -Milliseconds 800

$after = Get-Count $best
Write-Host ("重画后：元素={0}  文本节点={1}" -f $after.elems, $after.texts)

# ---- 判定：让用户自己看一眼最准，这里只给数 ----
if ($after.texts -le 0) {
  Write-Host "树里还是没有文本，光重画救不回来——重启这个实例（别动别的号）。" -ForegroundColor Yellow
  exit 3
}
Write-Host "树是好的。窗口要是还白，再看一眼；白着就重启实例。" -ForegroundColor Green
