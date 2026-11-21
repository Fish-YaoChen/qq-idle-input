# qq-popups.ps1 —— QQ 留在最上层的浮窗（资料卡之类），把底下的点击吃掉了
#
# 症状：屏幕某一块能看见、鼠标能移过去，但点不动；截屏软件能框出那块。
#       那块地方压着一张 QQ 的浮窗（资料卡最常见），它带 TOPMOST、又看不见，
#       所以它把鼠标事件全吃了。
# 做法：列出 QQ 进程里「置顶 + 工具窗 + 有面积 + 标题不是 QQ」的窗口；-Fix 时关掉它们。
#       只用 PostMessage(WM_CLOSE)，不碰键盘鼠标、不动主窗、不碰登录态。
#
# 用法：
#   .\qq-popups.ps1              # 只列
#   .\qq-popups.ps1 -Fix         # 列并关掉
#   .\qq-popups.ps1 -Uin <你的号> -Fix

[CmdletBinding()]
param(
  [string]$Uin,
  [switch]$Fix
)

$ErrorActionPreference = 'Stop'
if (-not ("__PU" -as [type])) {
  Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class __PU {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_TOPMOST = 0x8;
  public const int WS_EX_TOOLWINDOW = 0x80;

  // 返回：hwnd|类名|标题|左,上,右,下|可见|置顶|工具窗
  public static List<string> Scan(uint pid) {
    var l = new List<string>();
    EnumWindows((h, p) => {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp != pid) return true;
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (c.ToString() != "Chrome_WidgetWin_1") return true;
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      string title = t.ToString();
      if (title == "QQ" || title.Length == 0) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      int w = r.R - r.L, hh = r.B - r.T;
      if (w < 100 || hh < 100) return true;                 // 托盘小窗不算
      int ex = GetWindowLong(h, GWL_EXSTYLE);
      bool top = (ex & WS_EX_TOPMOST) != 0;
      bool tool = (ex & WS_EX_TOOLWINDOW) != 0;
      if (!top || !tool) return true;                        // 只看置顶的工具浮窗
      l.Add(string.Format("{0}|{1}|{2}|{3},{4},{5},{6}|{7}|{8}|{9}",
        h, c, title, r.L, r.T, r.R, r.B, IsWindowVisible(h) ? 1 : 0, top ? 1 : 0, tool ? 1 : 0));
      return true;
    }, IntPtr.Zero);
    return l;
  }
  public static bool Close(IntPtr h) { return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
  public static bool Hide(IntPtr h) { return ShowWindow(h, 0); }
}
"@
}

$where = "Name='QQ.exe'"
$procs = Get-CimInstance Win32_Process -Filter $where | Where-Object {
  $Uin -eq '' -or $_.CommandLine -match [regex]::Escape($Uin)
}
if (-not $procs) { Write-Host "没找到 QQ 进程。"; exit 1 }

$any = $false
foreach ($p in $procs) {
  $rows = [__PU]::Scan([uint32]$p.ProcessId)
  if (-not $rows) { continue }
  $uin = if ($p.CommandLine -match 'from-multiple-login\s+(\d+)') { $Matches[1] } else { '?' }
  foreach ($row in $rows) {
    $any = $true
    $f = $row.Split('|')
    $hwnd = [IntPtr][long]$f[0]
    Write-Host ("PID={0} 号={1} 浮窗「{2}」 hwnd={3} 矩形=({4}) 可见={5}" -f $p.ProcessId, $uin, $f[2], $f[0], $f[3], $f[7])
    if ($Fix) {
      [void][__PU]::Close($hwnd)
      Start-Sleep -Milliseconds 400
      [void][__PU]::Hide($hwnd)      # 关不掉就先藏，反正不能让它挡着
      Write-Host "  → 已关（关不掉就藏起来）"
    }
  }
}
if (-not $any) {
  Write-Host "没找到置顶的 QQ 浮窗。要是还有一块点不动，把坐标告诉我，我按坐标反查是哪个窗。"
} elseif (-not $Fix) {
  Write-Host "（只看不动。要关就加 -Fix）"
}
