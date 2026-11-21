# qq-send.ps1 — 用 UIA 定位 + 真实键盘，把一句话发进 QQ。
#
# 为什么必须抢一下：输入框是 ProseMirror，UIA 只给 Text（只读），没有 ValuePattern；
# Chromium 又不认外面 PostMessage 过去的 WM_CHAR。所以「写字」只能靠真实键盘。
# 这一下不能省，能省的是——**只在发的那一瞬间抢**：
#   * 先空闲检测：你正在用键盘/鼠标（1.2 秒内有动作）就不发，等你空下来；
#   * 不点鼠标：会话用 Invoke 打开，输入框用 UIA SetFocus，不需要移动光标；
#   * 发完立刻把前台还给原来那个窗口，剪贴板也还原；
#   * 按回车之前先读一遍输入框，确认字真的进去了，没进去就绝不按。
#
# 用法：
#   powershell -File qq-send.ps1 -To "妈妈" -Text "试一句"          # 演练，只报计划和耗时估计
#   powershell -File qq-send.ps1 -To "妈妈" -Text "试一句" -Do     # 真发
#   powershell -File qq-send.ps1 -To "妈妈" -Text "试一句" -Do -MinIdleMs 2000
param(
  [Parameter(Mandatory = $true)][string]$To,
  [string]$Text,
  [string]$TextFile,          # 从文件读文本，避开命令行转义（中文、引号）
  [switch]$Do,
  [int]$MinIdleMs = 1200,
  [switch]$IgnoreIdle,
  [string]$Uin = "2727950855"
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class QQS {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] public struct WPLACE { public uint length, flags, showCmd; public POINT min, max; public RECT normal; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WPLACE w);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("kernel32.dll")] public static extern uint GetTickCount();

  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; public ulong pad1; }
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT { public uint type; public KEYBDINPUT ki; }
  public const uint INPUT_KEYBOARD = 1;
  public const uint KEYUP = 0x0002, UNICODE = 0x0004;
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

  public static void Tap(ushort vk) {
    INPUT d = new INPUT(); d.type = INPUT_KEYBOARD; d.ki.wVk = vk;
    INPUT u = new INPUT(); u.type = INPUT_KEYBOARD; u.ki.wVk = vk; u.ki.dwFlags = KEYUP;
    SendInput(1, new INPUT[]{d}, Marshal.SizeOf(typeof(INPUT)));
    SendInput(1, new INPUT[]{u}, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void CtrlV() {
    INPUT c1 = new INPUT(); c1.type = INPUT_KEYBOARD; c1.ki.wVk = 0x11;
    INPUT v1 = new INPUT(); v1.type = INPUT_KEYBOARD; v1.ki.wVk = 0x56;
    INPUT v2 = new INPUT(); v2.type = INPUT_KEYBOARD; v2.ki.wVk = 0x56; v2.ki.dwFlags = KEYUP;
    INPUT c2 = new INPUT(); c2.type = INPUT_KEYBOARD; c2.ki.wVk = 0x11; c2.ki.dwFlags = KEYUP;
    SendInput(4, new INPUT[]{c1,v1,v2,c2}, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void CtrlA() {
    INPUT c1 = new INPUT(); c1.type = INPUT_KEYBOARD; c1.ki.wVk = 0x11;
    INPUT a1 = new INPUT(); a1.type = INPUT_KEYBOARD; a1.ki.wVk = 0x41;
    INPUT a2 = new INPUT(); a2.type = INPUT_KEYBOARD; a2.ki.wVk = 0x41; a2.ki.dwFlags = KEYUP;
    INPUT c2 = new INPUT(); c2.type = INPUT_KEYBOARD; c2.ki.wVk = 0x11; c2.ki.dwFlags = KEYUP;
    SendInput(4, new INPUT[]{c1,a1,a2,c2}, Marshal.SizeOf(typeof(INPUT)));
  }
  // 直接发一个 Unicode 字符（不走输入法）
  public static void SendChar(ushort ch) {
    INPUT d = new INPUT(); d.type = INPUT_KEYBOARD; d.ki.wVk = 0; d.ki.wScan = ch; d.ki.dwFlags = UNICODE;
    INPUT u = new INPUT(); u.type = INPUT_KEYBOARD; u.ki.wVk = 0; u.ki.wScan = ch; u.ki.dwFlags = UNICODE | KEYUP;
    SendInput(1, new INPUT[]{d}, Marshal.SizeOf(typeof(INPUT)));
    SendInput(1, new INPUT[]{u}, Marshal.SizeOf(typeof(INPUT)));
  }
  public static uint IdleMs() { LASTINPUTINFO li = new LASTINPUTINFO(); li.cbSize = 8; GetLastInputInfo(ref li); return GetTickCount() - li.dwTime; }

  // 抢/还前台：直接 SetForegroundWindow 会被系统拒（11-20 实测「还回去」一次都没成）。
  // 正确做法是把本线程「接」到当前前台窗口的输入队列上，借它的资格改前台，再断开。

  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static bool Activate(IntPtr target) {
    IntPtr fg = GetForegroundWindow();
    if (fg == target) return true;
    uint fgPid; uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
    uint me = GetCurrentThreadId();
    bool attached = false;
    try {
      if (fgThread != me) attached = AttachThreadInput(me, fgThread, true);
      // 目标最小化时 SetForegroundWindow 会「成功」但窗口还缩在任务栏——11-20 被这个骗过一次
      if (IsIconic(target)) { ShowWindow(target, 9); System.Threading.Thread.Sleep(150); }
      bool ok = SetForegroundWindow(target);
      if (!ok) { ShowWindow(target, 9); ok = SetForegroundWindow(target); }   // 9 = SW_RESTORE
      return ok;
    } finally {
      if (attached) AttachThreadInput(me, fgThread, false);
    }
  }

  // 11-21：缩着的时候 GetWindowRect 只回一个小矩形（160x28），比面积会输给旁边的浮窗。
  // 最小化时改用「还原后」的位置。
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

function Log([string]$m) { Write-Host $m }

if ($TextFile) { if (Test-Path $TextFile) { $Text = (Get-Content $TextFile -Raw -Encoding utf8).Trim() } else { Write-Error "读不到文本文件：$TextFile"; exit 12 } }
if (-not $Text) { Write-Error "没有要发的文本（-Text 或 -TextFile）"; exit 13 }

# ---- 1. 找进程和窗口 ----
$proc = Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" |
  Where-Object { $_.CommandLine -like "*--from-multiple-login $Uin *" } | Select-Object -First 1
if (-not $proc) { Write-Error "没找到 QQ $Uin 的进程"; exit 2 }
$hwnd = [QQS]::FindByPid([uint32]$proc.ProcessId)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "没找到窗口"; exit 3 }

# ---- 2. 空闲检测：他在用电脑就不打扰 ----
$idle = [QQS]::IdleMs()
Log "空闲 $idle ms（门槛 $MinIdleMs）"
if ($idle -lt $MinIdleMs -and -not $IgnoreIdle) {
  Write-Error "你正在用电脑（$idle ms 内有输入），这一句不发。过一会儿再叫我。"
  exit 4
}
if (-not $Do) { Log "演练：会把「$To」打开、逐字打 $($Text.Length) 个字、点发送、再还原前台。"; exit 0 }

# ---- 3. 记下现在的前台和剪贴板 ----
$prevFg = [QQS]::GetForegroundWindow()
$prevClip = $null
try { $prevClip = Get-Clipboard -Raw -ErrorAction Stop } catch {}

# ---- 4. 打开会话（Invoke，不碰鼠标） ----
# 11-20 栽过一次：按名字随便找一个 Text 就往上级 Invoke，结果点到的是消息里的头像名，
# 会话压根没切，字打进了上一个开着的聊天（发到他私聊里去了）。改成只认「会话行」：
# 一行 = 一个 Group，直接子节点里有 2~3 个 Text，第一个 Text 就是昵称。
if (-not [QQS]::IsWindowVisible($hwnd)) { [QQS]::ShowWindow($hwnd, 4) | Out-Null; Start-Sleep -Milliseconds 500 }

# 打开之后必须核对：聊天窗口顶部写着谁的名字
function Get-OpenChatName {
  $w = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $hdr = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty, "chat-header__contact-name")))
  if ($hdr) { return $hdr.Current.Name }
  return ""
}
function Open-Session([string]$name) {
  $w = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $textCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Text)
  $groups = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Group)))
  foreach ($g in $groups) {
    $kids = $g.FindAll([System.Windows.Automation.TreeScope]::Children, $textCond)
    if ($kids.Count -lt 2 -or $kids.Count -gt 3) { continue }
    if ($kids[0].Current.Name -ne $name) { continue }
    $target = $g
    if (-not ($g.GetSupportedPatterns() | Where-Object { $_ -eq [System.Windows.Automation.InvokePattern]::Pattern })) {
      $target = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($g)
    }
    if ($target -and ($target.GetSupportedPatterns() | Where-Object { $_ -eq [System.Windows.Automation.InvokePattern]::Pattern })) {
      $target.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
      return $true
    }
  }
  return $false
}

# 打开可能要试两次：11-20 观察到 QQ 从托盘回来后第一次 Invoke 有时只选中、不打开会话。
$openedName = ""
# 11-21：这个版本的 QQ，点**已经选中**的那一行会把聊天区关掉——再点一次反而没标题、
# 输入框也拿不到焦点（今天发送就失败在这儿）。所以先看顶部：已经是这个人，一次都不点。
if ((Get-OpenChatName) -eq $To) {
  Log "要发的会话本来就开着，不点它。"
  $openedName = $To
} else {
for ($try = 1; $try -le 3; $try++) {
  if (-not (Open-Session $To)) { Write-Error "会话列表里没有「$To」这一行，**什么都没打**"; exit 5 }
  Start-Sleep -Milliseconds (300 + 250 * $try)
  $openedName = Get-OpenChatName
  if ($openedName -eq $To) { break }
  Log "第 $try 次打开后顶部是「$openedName」，再试"
}
}

Log "打开的是：「$openedName」"
if ($openedName -ne $To) {
  Write-Error "会话没切过去（顶部写的是「$openedName」，要的是「$To」），**什么都没打**"
  exit 5
}


# ---- 5. 找输入框 ----
$win = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$editor = $all | Where-Object { $_.Current.ClassName -like "*ExEditor*" } | Select-Object -First 1
if (-not $editor) { Write-Error "没找到输入框（会话可能没打开）"; exit 7 }

function Type-Text([string]$s, [int]$perCharMs) {
  # 逐字发 KEYEVENTF_UNICODE：绕过输入法，也不会被 QQ 的粘贴限制挡（11-20 实测 Ctrl+V 不认）
  foreach ($ch in $s.ToCharArray()) {
    [QQS]::SendChar([uint16][char]$ch)
    if ($perCharMs -gt 0) { Start-Sleep -Milliseconds $perCharMs }
  }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
# Windows 默认不让后台程序抢前台，先敲一下 Alt 解除这个锁（这是系统承认的「用户输入」）
[QQS]::Activate($hwnd) | Out-Null
Start-Sleep -Milliseconds 200
$isFront = ([QQS]::GetForegroundWindow() -eq $hwnd)
Log "前台是不是 QQ：$isFront"
if (-not $isFront) {
  Write-Error "没抢到前台，**什么都没输**（这是为了避免把字打到你别的窗口里）。耗时 $($sw.ElapsedMilliseconds) ms"
  exit 9
}

$head = $Text.Substring(0, [Math]::Min(6, $Text.Length))
$got = $false
for ($attempt = 1; $attempt -le 2 -and -not $got; $attempt++) {
  $winE = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $ed = $winE.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ClassName -like "*ExEditor*" } | Select-Object -First 1
  if (-not $ed) { break }
  $ed.SetFocus() | Out-Null
  Start-Sleep -Milliseconds 150
  [QQS]::CtrlA()          # 先把可能残留的草稿全选，下面打字直接覆盖
  Start-Sleep -Milliseconds 120
  Type-Text $Text 12
  Start-Sleep -Milliseconds 300
  $winE = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $ed = $winE.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ClassName -like "*ExEditor*" } | Select-Object -First 1
  if ($ed) {
    try { $doc = $ed.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(600) } catch { $doc = "" }
    if ($doc -and $doc.Contains($head)) { $got = $true }
  }
  if (-not $got) { Log "第 $attempt 次没打进去，再来一次" }
}

# ---- 7. 确认字真的进去了，才按回车 ----
if (-not $got) {
  [QQS]::Tap(0x12); [QQS]::SetForegroundWindow($prevFg) | Out-Null
  Write-Error "输入框里没读到刚打进去的字，**没有按回车**。耗时 $($sw.ElapsedMilliseconds) ms"
  exit 8
}
# 回车发不出去（11-20 实测：SendInput 的 Enter 被 QQ 忽略），改点「发送」按钮——
# 它支持 Invoke，不需要键盘，这也少了一次按键。
$winB = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$sendBtn = $winB.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
  Where-Object { $_.Current.ClassName -eq "send-msg" } | Select-Object -First 1
if (-not $sendBtn) {
  [QQS]::Activate($prevFg) | Out-Null
  Write-Error "没找到「发送」按钮，字留在输入框里没发。耗时 $($sw.ElapsedMilliseconds) ms"
  exit 10
}
$sendBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 400

# 发完必须回读输入框：11-20 就是没做这一步，把「字打进去了」当成「发出去了」报了。
$winV = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$edV = $winV.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
  Where-Object { $_.Current.ClassName -like "*ExEditor*" } | Select-Object -First 1
$left = ""
if ($edV) { try { $left = $edV.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(600) } catch {} }
if ($left -and $left.Contains($head)) {
  [QQS]::Activate($prevFg) | Out-Null
  Write-Error "字还留在输入框里，**这条没发出去**。耗时 $($sw.ElapsedMilliseconds) ms"
  exit 11
}

# ---- 8. 还回去 ----
[QQS]::Activate($prevFg) | Out-Null
Start-Sleep -Milliseconds 100
$sw.Stop()
Log "发出去了：$To ← $($Text.Substring(0,[Math]::Min(20,$Text.Length)))，前台被占 $($sw.ElapsedMilliseconds) ms"

